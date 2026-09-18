import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`. Values are clamped on load so a hand-edited plist
/// cannot put the engine in an invalid state.
@MainActor
@Observable
final class AppSettings {
    static let segmentRange = 1...32
    static let concurrencyRange = 1...10

    var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: Key.folder) } }
    /// Connections per download for new downloads.
    var segmentCount: Int { didSet { defaults.set(segmentCount, forKey: Key.segments) } }
    var maxConcurrentDownloads: Int { didSet { defaults.set(maxConcurrentDownloads, forKey: Key.concurrent) } }
    /// Kilobytes per second across all downloads; 0 means unlimited.
    var speedLimitKBps: Int { didSet { defaults.set(speedLimitKBps, forKey: Key.speedLimit) } }
    /// Off by default: watching the clipboard is opt-in.
    var detectClipboard: Bool { didSet { defaults.set(detectClipboard, forKey: Key.clipboard) } }
    var defaultUserAgent: String { didSet { defaults.set(defaultUserAgent, forKey: Key.userAgent) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let folder = "downloadFolder"
        static let segments = "segmentCount"
        static let concurrent = "maxConcurrentDownloads"
        static let speedLimit = "speedLimitKBps"
        static let clipboard = "detectClipboard"
        static let userAgent = "defaultUserAgent"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Downloads")
        downloadFolder = defaults.string(forKey: Key.folder).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? downloads
        segmentCount = Self.clamp(defaults.object(forKey: Key.segments) as? Int ?? 8, Self.segmentRange)
        maxConcurrentDownloads = Self.clamp(defaults.object(forKey: Key.concurrent) as? Int ?? 3, Self.concurrencyRange)
        speedLimitKBps = SpeedLimit.clamp(defaults.integer(forKey: Key.speedLimit))
        detectClipboard = defaults.bool(forKey: Key.clipboard)
        defaultUserAgent = defaults.string(forKey: Key.userAgent) ?? ""
    }

    /// The global limit in bytes per second, `nil` when unlimited.
    var globalSpeedLimit: Int64? { SpeedLimit.bytesPerSecond(kbps: speedLimitKBps) }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
