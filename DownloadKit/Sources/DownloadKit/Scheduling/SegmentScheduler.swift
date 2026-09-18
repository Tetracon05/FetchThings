import Foundation
import Synchronization

/// Hands out segments to connection slots and rebalances: when every segment is taken, a slot that
/// runs dry splits the segment with the most bytes left, so the slowest range never decides the
/// finish time.
///
/// Counters per segment: `received` is committed (on disk) and is what gets persisted. `reserved` is
/// what a worker has claimed the right to write; it runs ahead of `received` only during a write.
/// Stealing only ever takes bytes beyond `reserved`, so two workers can never write the same byte.
final class SegmentScheduler: Sendable {
    struct Attempt: Sendable, Equatable {
        /// First byte to request (segment start plus what is already on disk).
        let offset: Int64
        /// Last byte of the segment at the moment the attempt was prepared.
        let end: Int64
    }

    private struct Entry {
        var start: Int64
        var end: Int64
        var received: Int64
        var reserved: Int64
        var running: Bool

        var length: Int64 { end - start + 1 }
        var isComplete: Bool { received >= length }
    }

    private let entries: Mutex<[Entry]>
    private let minSplitSize: Int64

    /// - Parameter minSplitSize: a segment is only split when at least twice this many bytes remain.
    init(segments: [Segment], minSplitSize: Int64) {
        precondition(segments.enumerated().allSatisfy { $0.offset == $0.element.index }, "segment indices must be 0..<n")
        self.minSplitSize = max(1, minSplitSize)
        entries = Mutex(segments.map {
            Entry(start: $0.start, end: $0.end, received: $0.received, reserved: $0.start + $0.received, running: false)
        })
    }

    /// Takes the next incomplete idle segment, or splits a running one. `nil` when nothing is left to do.
    func claim() -> Int? {
        entries.withLock { entries in
            if let index = entries.indices.first(where: { !entries[$0].running && !entries[$0].isComplete }) {
                entries[index].running = true
                entries[index].reserved = entries[index].start + entries[index].received
                return index
            }
            var best: (index: Int, remaining: Int64)?
            for index in entries.indices where entries[index].running {
                let remaining = entries[index].end - entries[index].reserved + 1
                if remaining >= 2 * minSplitSize, remaining > (best?.remaining ?? 0) {
                    best = (index, remaining)
                }
            }
            guard let (victim, remaining) = best else { return nil }
            let splitAt = entries[victim].reserved + remaining / 2
            let stolen = Entry(start: splitAt, end: entries[victim].end, received: 0, reserved: splitAt, running: true)
            entries[victim].end = splitAt - 1
            entries.append(stolen)
            return entries.count - 1
        }
    }

    /// Re-derives the request range from what is committed. `nil` when the segment is complete.
    func prepareAttempt(_ index: Int) -> Attempt? {
        entries.withLock { entries in
            guard !entries[index].isComplete else { return nil }
            entries[index].reserved = entries[index].start + entries[index].received
            return Attempt(offset: entries[index].reserved, end: entries[index].end)
        }
    }

    /// Claims up to `count` bytes at the segment's write cursor. May return fewer (or zero) when the
    /// segment's end was moved by a steal.
    func reserve(_ index: Int, upTo count: Int) -> (offset: Int64, count: Int) {
        entries.withLock { entries in
            let offset = entries[index].reserved
            let room = max(0, entries[index].end - offset + 1)
            let granted = Int(min(Int64(count), room))
            entries[index].reserved += Int64(granted)
            return (offset, granted)
        }
    }

    func commit(_ index: Int, bytes: Int) {
        entries.withLock { $0[index].received += Int64(bytes) }
    }

    func release(_ index: Int) {
        entries.withLock { $0[index].running = false }
    }

    func isComplete(_ index: Int) -> Bool {
        entries.withLock { $0[index].isComplete }
    }

    /// True once nothing more may be reserved: the worker should stop reading.
    func isFullyReserved(_ index: Int) -> Bool {
        entries.withLock { $0[index].reserved > $0[index].end }
    }

    func received(_ index: Int) -> Int64 {
        entries.withLock { $0[index].received }
    }

    var isFinished: Bool {
        entries.withLock { $0.allSatisfy(\.isComplete) }
    }

    var receivedBytes: Int64 {
        entries.withLock { $0.reduce(0) { $0 + $1.received } }
    }

    var runningCount: Int {
        entries.withLock { $0.filter(\.running).count }
    }

    /// The persistable state.
    func segments() -> [Segment] {
        entries.withLock { entries in
            entries.enumerated().map { Segment(index: $0.offset, start: $0.element.start, end: $0.element.end, received: $0.element.received) }
        }
    }

    func snapshots() -> [SegmentSnapshot] {
        entries.withLock { entries in
            entries.enumerated().map {
                SegmentSnapshot(index: $0.offset, start: $0.element.start, end: $0.element.end, received: $0.element.received, isActive: $0.element.running)
            }
        }
    }
}
