import Foundation
import Synchronization

/// Where a transfer's bytes go. Called on the URLSession delegate queue, one chunk at a time.
protocol TransferTarget: Sendable {
    /// Writes as much of `data` as fits and returns how many bytes were taken. Returning fewer than
    /// `data.count` tells the transfer its range is full.
    func consume(_ data: Data) throws -> Int
    /// No more bytes can be accepted.
    var isFull: Bool { get }
}

/// One segment of a segmented download.
struct RangeTarget: TransferTarget {
    let scheduler: SegmentScheduler
    let index: Int
    let file: PartFile

    func consume(_ data: Data) throws -> Int {
        let grant = scheduler.reserve(index, upTo: data.count)
        guard grant.count > 0 else { return 0 }
        try file.write(grant.count == data.count ? data : data.prefix(grant.count), at: grant.offset)
        scheduler.commit(index, bytes: grant.count)
        return grant.count
    }

    var isFull: Bool { scheduler.isFullyReserved(index) }
}

/// A whole-body download: bytes are appended from offset zero.
final class StreamTarget: TransferTarget, Sendable {
    private let file: PartFile
    private let written = Mutex<Int64>(0)

    init(file: PartFile) {
        self.file = file
    }

    var receivedBytes: Int64 { written.withLock { $0 } }
    var isFull: Bool { false }

    func consume(_ data: Data) throws -> Int {
        let offset = written.withLock { $0 }
        try file.write(data, at: offset)
        written.withLock { $0 += Int64(data.count) }
        return data.count
    }

    /// Starts over: a retried plain GET returns the whole body again.
    func reset() throws {
        try file.truncate(to: 0)
        written.withLock { $0 = 0 }
    }
}
