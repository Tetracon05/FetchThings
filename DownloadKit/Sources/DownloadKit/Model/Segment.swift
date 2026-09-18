import Foundation

/// A contiguous byte range of the resource, and how much of it is already on disk.
public struct Segment: Codable, Sendable, Equatable {
    public var index: Int
    /// First byte, inclusive.
    public var start: Int64
    /// Last byte, inclusive.
    public var end: Int64
    /// Bytes of this segment written to disk, counted from `start`.
    public var received: Int64

    public init(index: Int, start: Int64, end: Int64, received: Int64 = 0) {
        self.index = index
        self.start = start
        self.end = end
        self.received = received
    }

    public var length: Int64 { end - start + 1 }
}

public enum SegmentPlanner {
    /// Whether `segments` (for instance read back from a job file) exactly tile `0..<totalSize`: indices are
    /// `0..<n`, ranges are contiguous and non-overlapping, and progress lies within each range. Anything
    /// else must not be trusted for a resume.
    public static func isValidPlan(_ segments: [Segment], totalSize: Int64) -> Bool {
        guard totalSize > 0, !segments.isEmpty,
              segments.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { return false }
        var nextStart: Int64 = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start == nextStart, segment.end >= segment.start, segment.end < totalSize,
                  segment.received >= 0, segment.received <= segment.length else { return false }
            nextStart = segment.end + 1
        }
        return nextStart == totalSize
    }

    /// Splits `totalSize` bytes into at most `requested` near-equal segments, none smaller than
    /// `minSegmentSize` (except when the whole file is smaller). A zero-length file has no segments.
    public static func plan(totalSize: Int64, requested: Int, minSegmentSize: Int64) -> [Segment] {
        guard totalSize > 0 else { return [] }
        let minSize = max(1, minSegmentSize)
        let byMinSize = max(1, totalSize / minSize)
        let count = Int(min(Int64(max(1, requested)), byMinSize))

        let base = totalSize / Int64(count)
        let remainder = totalSize % Int64(count)
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        var cursor: Int64 = 0
        for i in 0..<count {
            let length = base + (Int64(i) < remainder ? 1 : 0)
            segments.append(Segment(index: i, start: cursor, end: cursor + length - 1))
            cursor += length
        }
        return segments
    }
}
