import Testing
@testable import DownloadKit

@Suite("SegmentPlanner")
struct SegmentPlannerTests {
    @Test func splitsEvenly() {
        let mebibyte: Int64 = 1024 * 1024
        let segments = SegmentPlanner.plan(totalSize: 8 * mebibyte, requested: 8, minSegmentSize: mebibyte)
        #expect(segments.count == 8)
        #expect(segments.allSatisfy { $0.length == mebibyte })
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == 8 * mebibyte - 1)
    }

    @Test func spreadsTheRemainderOverTheFirstSegments() {
        let segments = SegmentPlanner.plan(totalSize: 10, requested: 3, minSegmentSize: 1)
        #expect(segments.map(\.length) == [4, 3, 3])
        #expect(segments.map(\.start) == [0, 4, 7])
    }

    @Test func neverMakesSegmentsSmallerThanTheMinimum() {
        let segments = SegmentPlanner.plan(totalSize: 3 * 1024 * 1024 + 5, requested: 8, minSegmentSize: 1024 * 1024)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.length >= 1024 * 1024 })
    }

    @Test func aSmallFileIsASingleSegment() {
        let segments = SegmentPlanner.plan(totalSize: 100, requested: 8, minSegmentSize: 1024 * 1024)
        #expect(segments == [Segment(index: 0, start: 0, end: 99)])
    }

    @Test func anEmptyFileHasNoSegments() {
        #expect(SegmentPlanner.plan(totalSize: 0, requested: 8, minSegmentSize: 1024).isEmpty)
    }

    @Test func requestingZeroOrNegativeSegmentsStillYieldsOne() {
        #expect(SegmentPlanner.plan(totalSize: 5000, requested: 0, minSegmentSize: 1).count == 1)
        #expect(SegmentPlanner.plan(totalSize: 5000, requested: -3, minSegmentSize: 1).count == 1)
    }

    @Test(arguments: [1, 7, 1000, 4096, 1_048_577, 10_000_000_019], [1, 2, 3, 8, 64])
    func segmentsTileTheFileExactly(total: Int64, requested: Int) {
        let segments = SegmentPlanner.plan(totalSize: total, requested: requested, minSegmentSize: 512)
        #expect(segments.map(\.index) == Array(0..<segments.count))
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == total - 1)
        for (previous, next) in zip(segments, segments.dropFirst()) {
            #expect(next.start == previous.end + 1, "segments must be contiguous")
        }
        #expect(segments.reduce(0) { $0 + $1.length } == total)
        let lengths = segments.map(\.length)
        #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1)
    }
}
