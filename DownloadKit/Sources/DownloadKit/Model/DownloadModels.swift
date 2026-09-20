import Foundation

public typealias DownloadID = UUID

public enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued, probing, downloading, paused, verifying, completed, failed

    /// States in which a job occupies one of the queue's concurrency slots.
    public var isRunning: Bool { self == .probing || self == .downloading || self == .verifying }
    public var isFinished: Bool { self == .completed || self == .failed }
}

public enum TransferMode: String, Codable, Sendable {
    /// Server supports byte ranges and reports a size: split across connections, resumable.
    case segmented
    /// One plain GET. Not resumable: a resume restarts from zero.
    case single
}

public struct BasicAuth: Codable, Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Everything that must never land in the plain-text job store: it is kept in a `SecretStore`.
public struct SensitiveOptions: Codable, Sendable, Equatable {
    /// Value of the `Cookie` header.
    public var cookies: String?
    public var headers: [String: String]
    public var basicAuth: BasicAuth?

    public init(cookies: String? = nil, headers: [String: String] = [:], basicAuth: BasicAuth? = nil) {
        self.cookies = cookies
        self.headers = headers
        self.basicAuth = basicAuth
    }

    public var isEmpty: Bool { cookies == nil && headers.isEmpty && basicAuth == nil }
}

public struct DownloadOptions: Codable, Sendable, Equatable {
    /// `nil` uses the engine default.
    public var segmentCount: Int?
    public var referer: URL?
    public var userAgent: String?
    /// Bytes per second; `nil` is unlimited.
    public var speedLimit: Int64?
    public var checksum: Checksum?
    /// Per-segment retry budget; `nil` uses the engine default.
    public var maxRetries: Int?

    public init(
        segmentCount: Int? = nil,
        referer: URL? = nil,
        userAgent: String? = nil,
        speedLimit: Int64? = nil,
        checksum: Checksum? = nil,
        maxRetries: Int? = nil
    ) {
        self.segmentCount = segmentCount
        self.referer = referer
        self.userAgent = userAgent
        self.speedLimit = speedLimit
        self.checksum = checksum
        self.maxRetries = maxRetries
    }
}

public struct NewDownload: Sendable {
    public var url: URL
    public var destinationDirectory: URL
    /// Overrides the server-suggested filename. Still sanitized.
    public var filename: String?
    public var options: DownloadOptions
    public var sensitive: SensitiveOptions
    public var startPaused: Bool

    public init(
        url: URL,
        destinationDirectory: URL,
        filename: String? = nil,
        options: DownloadOptions = .init(),
        sensitive: SensitiveOptions = .init(),
        startPaused: Bool = false
    ) {
        self.url = url
        self.destinationDirectory = destinationDirectory
        self.filename = filename
        self.options = options
        self.sensitive = sensitive
        self.startPaused = startPaused
    }
}

/// The persisted form of a download. Contains no secrets.
public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: DownloadID
    public var url: URL
    public var destinationDirectory: URL
    public var requestedFilename: String?
    /// The reserved, sanitized name. After completion, the name actually written.
    public var filename: String?
    public var options: DownloadOptions
    public var state: DownloadState
    public var mode: TransferMode?
    public var totalBytes: Int64?
    /// Bytes received in `.single` mode, and the final size after completion.
    public var receivedBytes: Int64
    public var segments: [Segment]
    public var etag: String?
    public var lastModified: String?
    public var failure: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var sequence: Int
    public var checksumVerified: Bool?
    /// Whether this download was added with cookies, headers or credentials, which live in the `SecretStore`.
    /// Recorded so that secrets which cannot be read later fail the download instead of silently
    /// downloading without them. (Optional so job files written before this field existed still load.)
    public var hasSecrets: Bool?

    public init(
        id: DownloadID = UUID(),
        url: URL,
        destinationDirectory: URL,
        requestedFilename: String? = nil,
        options: DownloadOptions = .init(),
        state: DownloadState = .queued,
        sequence: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.destinationDirectory = destinationDirectory
        self.requestedFilename = requestedFilename
        self.filename = nil
        self.options = options
        self.state = state
        self.mode = nil
        self.totalBytes = nil
        self.receivedBytes = 0
        self.segments = []
        self.etag = nil
        self.lastModified = nil
        self.failure = nil
        self.createdAt = createdAt
        self.completedAt = nil
        self.sequence = sequence
        self.checksumVerified = nil
        self.hasSecrets = nil
    }

    /// Bytes that survive a stop. A `.single` download restarts from zero, so until it completes it has
    /// nothing to resume from.
    public var downloadedBytes: Int64 {
        switch mode {
        case .segmented: segments.reduce(0) { $0 + $1.received }
        default: state == .completed ? receivedBytes : 0
        }
    }

    public var finalURL: URL? {
        filename.map { destinationDirectory.appending(path: $0, directoryHint: .notDirectory) }
    }
}

public struct SegmentSnapshot: Sendable, Equatable {
    public var index: Int
    public var start: Int64
    public var end: Int64
    public var received: Int64
    public var isActive: Bool

    public init(index: Int, start: Int64, end: Int64, received: Int64, isActive: Bool) {
        self.index = index
        self.start = start
        self.end = end
        self.received = received
        self.isActive = isActive
    }

    init(_ segment: Segment, isActive: Bool) {
        self.init(index: segment.index, start: segment.start, end: segment.end, received: segment.received, isActive: isActive)
    }
}

/// An immutable view of a download for the UI.
public struct DownloadSnapshot: Sendable, Identifiable, Equatable {
    public var id: DownloadID
    public var url: URL
    public var filename: String?
    public var destinationDirectory: URL
    public var state: DownloadState
    public var mode: TransferMode?
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var bytesPerSecond: Double
    public var eta: TimeInterval?
    public var activeConnections: Int
    public var segments: [SegmentSnapshot]
    public var failure: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var speedLimit: Int64?
    public var checksumVerified: Bool?
    public var finalURL: URL?
    /// The order downloads were added in (counts up). Records created within the same millisecond share a
    /// `createdAt`, and job files keep only milliseconds, so this is what puts a batch back in order.
    public var sequence: Int

    public init(
        id: DownloadID = UUID(),
        url: URL,
        filename: String? = nil,
        destinationDirectory: URL,
        state: DownloadState = .queued,
        mode: TransferMode? = nil,
        totalBytes: Int64? = nil,
        receivedBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        eta: TimeInterval? = nil,
        activeConnections: Int = 0,
        segments: [SegmentSnapshot] = [],
        failure: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        speedLimit: Int64? = nil,
        checksumVerified: Bool? = nil,
        finalURL: URL? = nil,
        sequence: Int = 0
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.destinationDirectory = destinationDirectory
        self.state = state
        self.mode = mode
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.bytesPerSecond = bytesPerSecond
        self.eta = eta
        self.activeConnections = activeConnections
        self.segments = segments
        self.failure = failure
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.speedLimit = speedLimit
        self.checksumVerified = checksumVerified
        self.finalURL = finalURL
        self.sequence = sequence
    }

    /// 0...1, or `nil` when the total size is unknown.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .completed ? 1 : nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    public var supportsResume: Bool { mode == .segmented }
}

public enum DownloadEvent: Sendable {
    case snapshot(DownloadSnapshot)
    case removed(DownloadID)
}
