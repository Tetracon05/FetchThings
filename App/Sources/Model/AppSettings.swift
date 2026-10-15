import DownloadKit
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
    // The numbers below keep themselves in range whoever writes them (a field in Settings, and later a menu bar item or
    // a schedule): a value out of range is put back before it is stored, so no writer has to remember to clamp. The
    // put-back is guarded by `!=`: under `@Observable` every assignment, of the same value too, runs `didSet` again, so
    // an unguarded one recurses without end.
    /// Connections per download for new downloads.
    var segmentCount: Int {
        didSet {
            let kept = Self.segmentRange.clamp(segmentCount)
            if kept != segmentCount { segmentCount = kept }
            defaults.set(segmentCount, forKey: Key.segments)
        }
    }
    var maxConcurrentDownloads: Int {
        didSet {
            let kept = Self.concurrencyRange.clamp(maxConcurrentDownloads)
            if kept != maxConcurrentDownloads { maxConcurrentDownloads = kept }
            defaults.set(maxConcurrentDownloads, forKey: Key.concurrent)
        }
    }
    /// The current speed mode: which of the limits below applies to all downloads together.
    var speedMode: SpeedMode { didSet { defaults.set(speedMode.rawValue, forKey: Key.speedMode) } }
    /// Kilobytes per second in Low mode. Never below 1: zero would mean unlimited.
    var lowLimitKBps: Int {
        didSet {
            let kept = Self.limit(lowLimitKBps, default: SpeedMode.defaultLowKBps)
            if kept != lowLimitKBps { lowLimitKBps = kept }
            defaults.set(lowLimitKBps, forKey: Key.lowLimit)
        }
    }
    /// Kilobytes per second in Normal mode. Never below 1, for the same reason.
    var normalLimitKBps: Int {
        didSet {
            let kept = Self.limit(normalLimitKBps, default: SpeedMode.defaultNormalKBps)
            if kept != normalLimitKBps { normalLimitKBps = kept }
            defaults.set(normalLimitKBps, forKey: Key.normalLimit)
        }
    }
    /// Keep downloads off a Personal Hotspot or cellular connection (which may be metered). Off: most people who tether
    /// do so to download.
    var pauseOnExpensiveNetwork: Bool { didSet { defaults.set(pauseOnExpensiveNetwork, forKey: Key.pauseExpensive) } }
    /// Keep downloads off a network that is in Low Data Mode, which is the system's way of asking apps to spare it. On.
    var pauseOnConstrainedNetwork: Bool { didSet { defaults.set(pauseOnConstrainedNetwork, forKey: Key.pauseConstrained) } }
    /// Off by default: watching the clipboard is opt-in.
    var detectClipboard: Bool { didSet { defaults.set(detectClipboard, forKey: Key.clipboard) } }
    var defaultUserAgent: String { didSet { defaults.set(defaultUserAgent, forKey: Key.userAgent) } }
    /// The system's preferred language, or one that overrides it. `AppleLanguages` is read once at launch (the same
    /// mechanism as Xcode's own "App Language" scheme setting and the `-AppleLanguages` launch argument), so a change
    /// only takes effect once the app relaunches.
    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language == .system ? nil : language.rawValue, forKey: Key.language)
            // `AppleLanguages` is what `Bundle` actually reads; removing it falls back to whatever is above it in the
            // search list (ordinarily the system's own preference), which is why `language` is also kept under its own
            // key: reading `AppleLanguages` back could otherwise find that same system value and mistake it for a
            // choice this app made.
            if language == .system {
                defaults.removeObject(forKey: Key.appleLanguages)
            } else {
                defaults.set([language.rawValue], forKey: Key.appleLanguages)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let folder = "downloadFolder"
        static let segments = "segmentCount"
        static let concurrent = "maxConcurrentDownloads"
        static let speedMode = "speedMode"
        static let lowLimit = "lowLimitKBps"
        static let normalLimit = "normalLimitKBps"
        static let pauseExpensive = "pauseOnExpensiveNetwork"
        static let pauseConstrained = "pauseOnConstrainedNetwork"
        static let clipboard = "detectClipboard"
        static let userAgent = "defaultUserAgent"
        static let language = "language"
        /// Apple's own key, not a namespaced one: it must live where `Bundle`'s language resolution actually looks.
        static let appleLanguages = "AppleLanguages"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Downloads")
        downloadFolder = defaults.string(forKey: Key.folder).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? downloads
        segmentCount = Self.segmentRange.clamp(defaults.object(forKey: Key.segments) as? Int ?? 8)
        maxConcurrentDownloads = Self.concurrencyRange.clamp(defaults.object(forKey: Key.concurrent) as? Int ?? 3)
        // High (unlimited) unless the user chose otherwise: that is how the app behaved before modes existed.
        speedMode = defaults.string(forKey: Key.speedMode).flatMap(SpeedMode.init(rawValue:)) ?? .high
        lowLimitKBps = Self.limit(defaults.object(forKey: Key.lowLimit) as? Int, default: SpeedMode.defaultLowKBps)
        normalLimitKBps = Self.limit(defaults.object(forKey: Key.normalLimit) as? Int, default: SpeedMode.defaultNormalKBps)
        pauseOnExpensiveNetwork = defaults.bool(forKey: Key.pauseExpensive)
        pauseOnConstrainedNetwork = defaults.object(forKey: Key.pauseConstrained) as? Bool ?? true
        detectClipboard = defaults.bool(forKey: Key.clipboard)
        defaultUserAgent = defaults.string(forKey: Key.userAgent) ?? ""
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The limit of a mode in KB/s; 0 (unlimited) for High.
    func limitKBps(for mode: SpeedMode) -> Int {
        switch mode {
        case .low: lowLimitKBps
        case .normal: normalLimitKBps
        case .high: 0
        }
    }

    /// Which connections downloads may use.
    var networkPolicy: NetworkPolicy {
        NetworkPolicy(pauseOnExpensive: pauseOnExpensiveNetwork, pauseOnConstrained: pauseOnConstrainedNetwork)
    }

    /// The global limit in bytes per second, `nil` when unlimited.
    var globalSpeedLimit: Int64? { SpeedLimit.bytesPerSecond(kbps: limitKBps(for: speedMode)) }

    /// A stored or typed limit for Low or Normal, kept in 1...`SpeedLimit.maxKBps`.
    static func limit(_ value: Int?, default fallback: Int) -> Int {
        (1...SpeedLimit.maxKBps).clamp(value ?? fallback)
    }
}

extension ClosedRange {
    /// `value`, held inside the range.
    func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// A language FetchThings can be shown in, or `.system` for whichever of them the system prefers. The raw value is
/// the language code `AppleLanguages` is set to, so it must match `CFBundleLocalizations` in `project.yml`.
enum AppLanguage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Shown in its own language, like a system language picker, except for "System" itself.
    var title: String {
        switch self {
        case .system: String(localized: "System", comment: "Language setting: follow the system's language")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}
