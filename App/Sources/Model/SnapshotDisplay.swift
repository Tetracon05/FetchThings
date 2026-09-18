import DownloadKit
import Foundation

extension DownloadSnapshot {
    /// The best name available before, during and after the download.
    var displayName: String {
        if let filename, !filename.isEmpty { return filename }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    var category: FileCategory { FileCategory.classify(filename: filename ?? displayName) }

    var isPausable: Bool { state.isRunning || state == .queued }
    var isResumable: Bool { state == .paused || state == .failed }

    var statusText: String {
        switch state {
        case .queued: "Queued"
        case .probing: "Connecting…"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .verifying: "Verifying…"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    // Table sort keys: Comparable stand-ins for optional or enum values.
    var sizeSortKey: Int64 { totalBytes ?? -1 }
    var progressSortKey: Double { fraction ?? -1 }
    var etaSortKey: Double { eta ?? .infinity }
    var statusSortKey: Int { DownloadState.allCases.firstIndex(of: state) ?? 0 }
}

/// Display strings. `FormatStyle`s are used throughout because they are value types and thread-safe.
enum Formatters {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func size(_ count: Int64?) -> String {
        count.map(bytes) ?? "—"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1 ? "\(bytes(Int64(bytesPerSecond)))/s" : "—"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "< 1 sec" }
        let whole = Int(seconds.rounded())
        return Duration.seconds(whole).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func percent(_ fraction: Double?) -> String {
        fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }
}
