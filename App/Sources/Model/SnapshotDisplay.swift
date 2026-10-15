import DownloadKit
import Foundation

extension DownloadSnapshot {
    /// The best name available before, during and after the download.
    var displayName: String {
        if let filename, !filename.isEmpty { return filename }
        return url.displayFileName
    }

    /// The finished file's address; nil until the download has completed. (The engine only reports a `finalURL` for a
    /// completed download, so the state check only guards a snapshot built by hand.)
    var completedFileURL: URL? { state == .completed ? finalURL : nil }

    var category: FileCategory { FileCategory.classify(filename: filename ?? displayName) }

    var isPausable: Bool { state.isRunning || state == .queued }
    var isResumable: Bool { state == .paused || state == .failed }

    var statusText: String {
        switch state {
        case .queued: String(localized: "Queued")
        case .probing: String(localized: "Connecting…")
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .verifying: String(localized: "Verifying…")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        }
    }

    // Table sort keys: Comparable stand-ins for optional or enum values.
    var sizeSortKey: Int64 { totalBytes ?? -1 }
    var progressSortKey: Double { fraction ?? -1 }
    var etaSortKey: Double { eta ?? .infinity }
    var statusSortKey: Int { DownloadState.allCases.firstIndex(of: state) ?? 0 }
}

extension DownloadPriority {
    var title: String {
        switch self {
        case .high: String(localized: "High")
        case .normal: String(localized: "Normal")
        case .low: String(localized: "Low")
        }
    }
}

/// Display strings. `FormatStyle`s are used throughout because they are value types and thread-safe.
enum Formatters {
    static func bytes(_ count: Int64) -> String {
        // `spellsOutZero: false`: the default prints "Zero kB".
        count.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func size(_ count: Int64?) -> String {
        count.map(bytes) ?? "—"
    }

    /// A size per second: "1.5 MB/s". (`speed` for a measured rate, this for a limit that is already a whole number.)
    static func perSecond(_ count: Int64) -> String {
        String(localized: "\(bytes(count))/s")
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1 ? perSecond(Int64(exactly: bytesPerSecond.rounded(.towardZero)) ?? .max) : "—"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return String(localized: "< 1 sec") }
        let whole = Int(seconds.rounded())
        return Duration.seconds(whole).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    static func percent(_ fraction: Double?) -> String {
        fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }
}
