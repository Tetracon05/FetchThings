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
    /// The current speed mode: which of the limits below applies to all downloads together.
    var speedMode: SpeedMode { didSet { defaults.set(speedMode.rawValue, forKey: Key.speedMode) } }
    /// Kilobytes per second in Low mode. Never below 1: zero would mean unlimited.
    var lowLimitKBps: Int { didSet { defaults.set(lowLimitKBps, forKey: Key.lowLimit) } }
    /// Kilobytes per second in Normal mode.
    var normalLimitKBps: Int { didSet { defaults.set(normalLimitKBps, forKey: Key.normalLimit) } }
    /// Off by default: watching the clipboard is opt-in.
    var detectClipboard: Bool { didSet { defaults.set(detectClipboard, forKey: Key.clipboard) } }
    var defaultUserAgent: String { didSet { defaults.set(defaultUserAgent, forKey: Key.userAgent) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let folder = "downloadFolder"
        static let segments = "segmentCount"
        static let concurrent = "maxConcurrentDownloads"
        static let speedMode = "speedMode"
        static let lowLimit = "lowLimitKBps"
        static let normalLimit = "normalLimitKBps"
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
        // High (unlimited) unless the user chose otherwise: that is how the app behaved before modes existed.
        speedMode = defaults.string(forKey: Key.speedMode).flatMap(SpeedMode.init(rawValue:)) ?? .high
        lowLimitKBps = Self.limit(defaults.object(forKey: Key.lowLimit) as? Int, default: SpeedMode.defaultLowKBps)
        normalLimitKBps = Self.limit(defaults.object(forKey: Key.normalLimit) as? Int, default: SpeedMode.defaultNormalKBps)
        detectClipboard = defaults.bool(forKey: Key.clipboard)
        defaultUserAgent = defaults.string(forKey: Key.userAgent) ?? ""
    }

    /// The limit of a mode in KB/s; 0 (unlimited) for High.
    func limitKBps(for mode: SpeedMode) -> Int {
        switch mode {
        case .low: lowLimitKBps
        case .normal: normalLimitKBps
        case .high: 0
        }
    }

    /// The global limit in bytes per second, `nil` when unlimited.
    var globalSpeedLimit: Int64? { SpeedLimit.bytesPerSecond(kbps: limitKBps(for: speedMode)) }

    /// A stored or typed limit for Low or Normal, kept in 1...`SpeedLimit.maxKBps`.
    static func limit(_ value: Int?, default fallback: Int) -> Int {
        min(max(value ?? fallback, 1), SpeedLimit.maxKBps)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
