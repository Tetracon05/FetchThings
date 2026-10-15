import Foundation

/// How soon a download runs compared with others. A higher priority is always started before a lower one; within one
/// priority, downloads go in the order they were added.
public enum DownloadPriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = -1
    case normal = 0
    case high = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a download stands in the queue: higher priority first, then the earlier one added.
/// `Comparable` in the order downloads are started, so the smallest one goes next.
public struct QueueOrder: Comparable, Hashable, Sendable {
    public var priority: DownloadPriority
    public var sequence: Int

    public init(priority: DownloadPriority, sequence: Int) {
        self.priority = priority
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.sequence < rhs.sequence
    }
}

extension DownloadSnapshot {
    public var queueOrder: QueueOrder { QueueOrder(priority: priority, sequence: sequence) }
}

extension DownloadRecord {
    /// Job files written before priority existed have no value: they run at normal priority.
    public var effectivePriority: DownloadPriority { priority ?? .normal }
}
