import Foundation
import Synchronization
import Testing
@testable import DownloadKit

@Suite("SegmentScheduler")
struct SegmentSchedulerTests {
    private func scheduler(total: Int64, segments: Int, minSplit: Int64 = 10) -> SegmentScheduler {
        SegmentScheduler(segments: SegmentPlanner.plan(totalSize: total, requested: segments, minSegmentSize: 1), minSplitSize: minSplit)
    }

    @Test func handsOutIdleSegmentsInOrder() {
        let s = scheduler(total: 100, segments: 4)
        #expect([s.claim(), s.claim(), s.claim(), s.claim()] == [0, 1, 2, 3])
    }

    @Test func stealsHalfOfTheLargestRemainingRangeWhenNothingIsIdle() throws {
        let s = scheduler(total: 200, segments: 2, minSplit: 10) // [0,99] and [100,199]
        _ = s.claim(); _ = s.claim()
        // Segment 1 has written 60 bytes; segment 0 none.
        _ = s.prepareAttempt(1)
        let grant = s.reserve(1, upTo: 60)
        s.commit(1, bytes: grant.count)

        let stolen = try #require(s.claim())
        #expect(stolen == 2)
        let segments = s.segments()
        // Victim is segment 0 (100 left, vs 40 left in segment 1); it keeps the first half.
        #expect(segments[0].end == 49)
        #expect(segments[2].start == 50 && segments[2].end == 99)
    }

    @Test func doesNotSplitWhatIsTooSmall() {
        let s = scheduler(total: 30, segments: 2, minSplit: 10) // 15 bytes each, needs 20 to split
        _ = s.claim(); _ = s.claim()
        #expect(s.claim() == nil)
    }

    @Test func aShrunkSegmentStopsGrantingBytesAtItsNewEnd() {
        let s = scheduler(total: 200, segments: 1, minSplit: 10)
        _ = s.claim()
        _ = s.prepareAttempt(0)
        let first = s.reserve(0, upTo: 20)
        s.commit(0, bytes: first.count)
        _ = s.claim() // steals [110, 199]; victim keeps [0, 109]

        let next = s.reserve(0, upTo: 500)
        #expect(next.offset == 20)
        #expect(next.count == 90) // up to and including byte 109
        #expect(s.isFullyReserved(0))
        #expect(s.reserve(0, upTo: 1).count == 0)
    }

    @Test func resumePointsAreDerivedFromCommittedBytesOnly() throws {
        let s = SegmentScheduler(segments: [Segment(index: 0, start: 100, end: 199, received: 30)], minSplitSize: 10)
        #expect(s.claim() == 0)
        let attempt = try #require(s.prepareAttempt(0))
        #expect(attempt == .init(offset: 130, end: 199))

        // A write is granted but never committed (say, pwrite failed): the retry must start from 130 again.
        _ = s.reserve(0, upTo: 40)
        #expect(s.prepareAttempt(0)?.offset == 130)
    }

    @Test func completeSegmentsAreNeitherClaimedNorPrepared() {
        let s = SegmentScheduler(segments: [Segment(index: 0, start: 0, end: 9, received: 10)], minSplitSize: 5)
        #expect(s.claim() == nil)
        #expect(s.prepareAttempt(0) == nil)
        #expect(s.isFinished)
    }

    /// Many workers claiming, stealing and "writing" at once must reserve every byte exactly once.
    @Test func concurrentWorkersCoverEveryByteExactlyOnce() {
        let total = 2_000_000
        let s = scheduler(total: Int64(total), segments: 3, minSplit: 1000)
        let coverage = Mutex([UInt8](repeating: 0, count: total))

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            while let index = s.claim() {
                while let attempt = s.prepareAttempt(index) {
                    _ = attempt
                    // Odd chunk sizes, differing per worker, to provoke interleavings.
                    let grant = s.reserve(index, upTo: 997 + worker * 131)
                    if grant.count == 0 { break }
                    coverage.withLock { bytes in
                        for i in grant.offset..<(grant.offset + Int64(grant.count)) { bytes[Int(i)] &+= 1 }
                    }
                    s.commit(index, bytes: grant.count)
                }
                s.release(index)
            }
        }

        let counts = coverage.withLock { $0 }
        #expect(counts.allSatisfy { $0 == 1 }, "every byte must be written exactly once")
        #expect(s.isFinished)
        #expect(s.receivedBytes == Int64(total))
        #expect(s.segments().count > 3, "stealing should have created extra segments")
    }
}
