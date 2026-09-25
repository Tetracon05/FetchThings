import Foundation

/// How soon a download runs compared with others. A higher priority is always started before a lower one; within one
/// priority, downloads go in the order of their place in the queue.
public enum DownloadPriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = -1
    case normal = 0
    case high = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a download stands in the queue: higher priority first, then the lower `rank`, then the earlier one added.
/// `Comparable` in the order downloads are started, so the smallest one goes next.
public struct QueueOrder: Comparable, Hashable, Sendable {
    public var priority: DownloadPriority
    /// A position within the priority. Fractional, so a download can be put between two others by taking a number
    /// between theirs, without renumbering (and rewriting the job file of) everything after it.
    public var rank: Double
    public var sequence: Int

    public init(priority: DownloadPriority, rank: Double, sequence: Int) {
        self.priority = priority
        self.rank = rank
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.sequence < rhs.sequence
    }
}

extension DownloadSnapshot {
    public var queueOrder: QueueOrder { QueueOrder(priority: priority, rank: queueRank, sequence: sequence) }
}

extension DownloadRecord {
    /// Job files written before the queue could be reordered have neither field: they run in the order they were added.
    public var effectivePriority: DownloadPriority { priority ?? .normal }
    public var effectiveRank: Double { queueRank ?? Double(sequence) }
}

/// Ranks for `count` downloads that are to sit between `low` and `high` (either may be missing: the start or the end
/// of the queue), keeping their order.
enum QueueRanks {
    /// Below this the gap is too small to divide again: the queue is renumbered.
    static let smallestGap = 1e-9

    static func spread(_ count: Int, between low: Double?, and high: Double?) -> [Double]? {
        guard count > 0 else { return [] }
        switch (low, high) {
        case (nil, nil): return (0 ..< count).map(Double.init)
        case (let low?, nil): return (1 ... count).map { low + Double($0) }
        case (nil, let high?): return (0 ..< count).map { high - Double(count - $0) }
        case (let low?, let high?):
            let step = (high - low) / Double(count + 1)
            guard step > smallestGap else { return nil }
            return (1 ... count).map { low + step * Double($0) }
        }
    }
}
