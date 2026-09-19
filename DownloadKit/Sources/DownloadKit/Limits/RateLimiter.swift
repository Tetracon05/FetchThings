import Foundation
import Synchronization

/// Decides how long a transfer must pause after receiving bytes. Callable from any thread.
public protocol RateLimiting: Sendable {
    /// Accounts for `bytes` just received; returns how long to stall before receiving more.
    func reserve(_ bytes: Int) -> TimeInterval
    /// Stall time still owed, without consuming anything.
    func pendingDelay() -> TimeInterval
    /// The most bytes a single request should ask for, or `nil` when there is no reason to hold back. Stalling a
    /// connection cannot keep URLSession from reading several megabytes ahead of the stall, so a limit is only
    /// as good as the amount each request is allowed to fetch: small requests bound the read-ahead.
    var maxRequestBytes: Int? { get }
}

extension RateLimiting {
    public var maxRequestBytes: Int? { nil }
}

/// Token bucket. Bytes are spent after they arrive, so the bucket can go into debt; the debt is what
/// the caller has to wait out. A `nil` or non-positive rate means unlimited.
public final class RateLimiter: RateLimiting, Sendable {
    private struct State {
        var rate: Double?
        var level: Double
        var last: TimeInterval
    }

    /// How much unused allowance can accumulate, in seconds of traffic at the current rate.
    private static let burstSeconds = 0.25

    private let state: Mutex<State>
    private let now: @Sendable () -> TimeInterval

    public init(
        bytesPerSecond: Int64? = nil,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        let rate = Self.normalize(bytesPerSecond)
        state = Mutex(State(rate: rate, level: (rate ?? 0) * Self.burstSeconds, last: now()))
    }

    public var bytesPerSecond: Int64? {
        state.withLock { $0.rate.map { Int64($0) } }
    }

    public func setRate(_ bytesPerSecond: Int64?) {
        let t = now()
        state.withLock { s in
            refill(&s, at: t)
            let rate = Self.normalize(bytesPerSecond)
            s.rate = rate
            s.level = min(s.level, (rate ?? 0) * Self.burstSeconds)
        }
    }

    public func reserve(_ bytes: Int) -> TimeInterval {
        let t = now()
        return state.withLock { s in
            guard let rate = s.rate else { return 0 }
            refill(&s, at: t)
            s.level -= Double(bytes)
            return s.level < 0 ? -s.level / rate : 0
        }
    }

    public func pendingDelay() -> TimeInterval {
        let t = now()
        return state.withLock { s in
            guard let rate = s.rate else { return 0 }
            refill(&s, at: t)
            return s.level < 0 ? -s.level / rate : 0
        }
    }

    /// A quarter of a second of traffic at the current rate, but never so small that every request costs more in
    /// set-up than it delivers, and never so large that it defeats the purpose.
    public var maxRequestBytes: Int? {
        state.withLock { s in
            s.rate.map { min(Self.largestRequest, max(Self.smallestRequest, Int($0 * Self.requestSeconds))) }
        }
    }

    static let smallestRequest = 128 * 1024
    static let largestRequest = 4 * 1024 * 1024
    private static let requestSeconds = 0.25

    private func refill(_ s: inout State, at t: TimeInterval) {
        defer { s.last = t }
        guard let rate = s.rate else { return }
        let elapsed = max(0, t - s.last)
        s.level = min(rate * Self.burstSeconds, s.level + elapsed * rate)
    }

    private static func normalize(_ rate: Int64?) -> Double? {
        guard let rate, rate > 0 else { return nil }
        return Double(rate)
    }
}

/// Applies several limiters at once (per-download plus global); the slowest one wins.
public struct CompositeLimiter: RateLimiting {
    public let limiters: [any RateLimiting]

    public init(_ limiters: [any RateLimiting]) {
        self.limiters = limiters
    }

    public func reserve(_ bytes: Int) -> TimeInterval {
        limiters.reduce(0) { max($0, $1.reserve(bytes)) }
    }

    public func pendingDelay() -> TimeInterval {
        limiters.reduce(0) { max($0, $1.pendingDelay()) }
    }

    public var maxRequestBytes: Int? {
        limiters.compactMap(\.maxRequestBytes).min()
    }
}
