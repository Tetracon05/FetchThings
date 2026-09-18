import Foundation

public struct RetryPolicy: Sendable, Equatable {
    /// Consecutive fruitless attempts tolerated before a segment gives up.
    public var maxAttempts = 5
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 60
    /// Random spread applied to each delay, as a fraction (0.25 = ±25%).
    public var jitter = 0.25
    /// Upper bound honored for a server's `Retry-After`.
    public var maxRetryAfter: TimeInterval = 300

    public init() {}

    /// Delay before retry number `attempt` (1-based): exponential, capped, jittered, and never
    /// shorter than the server's `Retry-After`.
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil, randomUnit: Double = .random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let backoff = min(maxDelay, baseDelay * pow(2, exponent))
        let spread = 1 + jitter * (2 * randomUnit - 1)
        let jittered = backoff * spread
        guard let retryAfter, retryAfter > 0 else { return jittered }
        return max(jittered, min(retryAfter, maxRetryAfter))
    }
}
