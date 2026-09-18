import Foundation

public struct EngineConfiguration: Sendable {
    public var maxConcurrentDownloads = 3
    public var defaultSegmentCount = 8
    /// Files smaller than two of these are never split; stealing needs two of them to be left.
    public var minSegmentSize: Int64 = 1 << 20
    public var retryPolicy = RetryPolicy()
    /// Idle timeout for a connection (no bytes for this long).
    public var requestTimeout: TimeInterval = 30
    public var progressInterval: Duration = .milliseconds(250)
    public var checkpointInterval: Duration = .seconds(2)
    /// Mark finished files as downloaded from the internet so Gatekeeper checks them.
    public var applyQuarantine = true
    /// Continue jobs that were running when the app last quit.
    public var autoResumeOnLoad = true
    /// Also block idle *system* sleep (App Nap is always suppressed while downloading).
    public var keepSystemAwake = false
    /// Sent when the download does not set its own. `nil` keeps the URLSession default.
    public var defaultUserAgent: String?

    public init() {}
}
