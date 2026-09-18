import Foundation
import Synchronization
import Testing
@testable import DownloadKit

/// A hand-cranked clock so limiter maths is exact and instant.
final class FakeClock: Sendable {
    private let time = Mutex(1000.0)
    var now: TimeInterval { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    var reader: @Sendable () -> TimeInterval { { [self] in now } }
}

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func unlimitedNeverDelays() {
        let limiter = RateLimiter(bytesPerSecond: nil)
        #expect(limiter.reserve(10_000_000) == 0)
        #expect(limiter.pendingDelay() == 0)
        #expect(RateLimiter(bytesPerSecond: 0).reserve(1) == 0)
        #expect(RateLimiter(bytesPerSecond: -5).reserve(1) == 0)
    }

    @Test func allowsAShortBurstThenPacesAtTheRate() {
        let clock = FakeClock()
        let limiter = RateLimiter(bytesPerSecond: 1000, now: clock.reader) // burst: 250 bytes
        #expect(limiter.reserve(250) == 0)
        // 500 more bytes with an empty bucket: 0.5 s of debt.
        #expect(abs(limiter.reserve(500) - 0.5) < 1e-9)
    }

    @Test func debtIsPaidOffByWaiting() {
        let clock = FakeClock()
        let limiter = RateLimiter(bytesPerSecond: 1000, now: clock.reader)
        _ = limiter.reserve(1250) // 250 burst + 1000 debt = 1 s
        #expect(abs(limiter.pendingDelay() - 1.0) < 1e-9)
        clock.advance(0.4)
        #expect(abs(limiter.pendingDelay() - 0.6) < 1e-9)
        clock.advance(0.6)
        #expect(limiter.pendingDelay() == 0)
    }

    @Test func idleTimeCannotBankMoreThanTheBurst() {
        let clock = FakeClock()
        let limiter = RateLimiter(bytesPerSecond: 1000, now: clock.reader)
        clock.advance(3600)
        #expect(limiter.reserve(250) == 0)
        #expect(limiter.reserve(1000) > 0.9, "an hour of idling must not allow a 1000-byte burst")
    }

    @Test func throughputConvergesToTheLimit() {
        let clock = FakeClock()
        let limiter = RateLimiter(bytesPerSecond: 50_000, now: clock.reader)
        var elapsed = 0.0
        let start = clock.now
        for _ in 0..<500 { // 500 x 10 KB = 5 MB
            let delay = limiter.reserve(10_000)
            clock.advance(delay)
            elapsed = clock.now - start
        }
        let rate = 5_000_000 / elapsed
        #expect(abs(rate - 50_000) / 50_000 < 0.06, "measured \(rate) B/s")
    }

    @Test func changingTheRateAppliesImmediately() {
        let clock = FakeClock()
        let limiter = RateLimiter(bytesPerSecond: 1000, now: clock.reader)
        _ = limiter.reserve(5000)
        limiter.setRate(nil)
        #expect(limiter.pendingDelay() == 0)
        limiter.setRate(2000)
        #expect(limiter.bytesPerSecond == 2000)
    }

    @Test func compositeAppliesTheSlowestLimiter() {
        let clock = FakeClock()
        let fast = RateLimiter(bytesPerSecond: 10_000, now: clock.reader)
        let slow = RateLimiter(bytesPerSecond: 1_000, now: clock.reader)
        let both = CompositeLimiter([fast, slow, RateLimiter(bytesPerSecond: nil)])
        let delay = both.reserve(2_250)
        #expect(abs(delay - 2.0) < 1e-9)
        #expect(abs(both.pendingDelay() - 2.0) < 1e-9)
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    private var policy: RetryPolicy {
        var p = RetryPolicy()
        p.baseDelay = 1
        p.maxDelay = 30
        p.jitter = 0.25
        return p
    }

    @Test func backsOffExponentiallyAndCaps() {
        let p = policy
        let delays = (1...8).map { p.delay(forAttempt: $0, randomUnit: 0.5) } // 0.5 = no jitter
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
    }

    @Test func jitterStaysWithinBounds() {
        let p = policy
        #expect(p.delay(forAttempt: 3, randomUnit: 0) == 3) // 4 s minus 25%
        #expect(p.delay(forAttempt: 3, randomUnit: 1) == 5) // 4 s plus 25%
    }

    @Test func retryAfterIsAFloorButCapped() {
        let p = policy
        #expect(p.delay(forAttempt: 1, retryAfter: 20, randomUnit: 0.5) == 20)
        #expect(p.delay(forAttempt: 5, retryAfter: 2, randomUnit: 0.5) == 16, "a short Retry-After must not shorten backoff")
        #expect(p.delay(forAttempt: 1, retryAfter: 100_000, randomUnit: 0.5) == p.maxRetryAfter)
    }

    @Test func classifiesErrors() {
        #expect(DownloadError.httpStatus(503, retryAfter: nil).isRetryable)
        #expect(DownloadError.httpStatus(429, retryAfter: 5).isRetryable)
        #expect(DownloadError.httpStatus(408, retryAfter: nil).isRetryable)
        #expect(DownloadError.network(URLError.timedOut.rawValue).isRetryable)
        #expect(DownloadError.network(URLError.networkConnectionLost.rawValue).isRetryable)
        #expect(DownloadError.shortRead.isRetryable)

        #expect(!DownloadError.httpStatus(404, retryAfter: nil).isRetryable)
        #expect(!DownloadError.httpStatus(403, retryAfter: nil).isRetryable)
        #expect(!DownloadError.httpStatus(501, retryAfter: nil).isRetryable)
        #expect(!DownloadError.network(URLError.serverCertificateUntrusted.rawValue).isRetryable)
        #expect(!DownloadError.network(URLError.cancelled.rawValue).isRetryable)
        #expect(!DownloadError.fileSystem("disk full").isRetryable)
        #expect(!DownloadError.checksumMismatch(expected: "a", actual: "b").isRetryable)
    }
}
