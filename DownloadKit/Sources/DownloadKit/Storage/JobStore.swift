import Foundation

/// Persists download records so queued, paused and interrupted downloads survive a restart.
public protocol JobStore: Sendable {
    /// Every readable record, ordered by queue position. Unreadable files are skipped.
    func loadAll() async throws -> [DownloadRecord]
    func save(_ record: DownloadRecord) async throws
    func delete(id: DownloadID) async throws
    /// Returns once every save and delete requested before this call has finished. Stores that write
    /// synchronously need do nothing.
    func flush() async
}

extension JobStore {
    public func flush() async {}
}

/// One JSON file per download, so a progress checkpoint rewrites a few hundred bytes rather than the
/// whole list. The directory is private to the user (0700) because URLs can carry tokens.
public actor FileJobStore: JobStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle()

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        // Fractional seconds matter: downloads added together differ by milliseconds, and `.iso8601` rounds
        // that away, which scrambled the order of a batch after a restart.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.fractionalStyle))
        }
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        // Job files written before that change hold whole seconds, so both forms are read.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Self.fractionalStyle) { return date }
            return try Date(text, strategy: Self.wholeSecondStyle)
        }
    }

    public func loadAll() throws -> [DownloadRecord] {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? decoder.decode(DownloadRecord.self, from: $0) } }
            .sorted { ($0.sequence, $0.createdAt) < ($1.sequence, $1.createdAt) }
    }

    public func save(_ record: DownloadRecord) throws {
        try ensureDirectory()
        let file = fileURL(record.id)
        try encoder.encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func delete(id: DownloadID) throws {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// An actor runs one call at a time, in order: by the time this runs, earlier saves are on disk.
    public func flush() {}

    private func fileURL(_ id: DownloadID) -> URL {
        directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
}
