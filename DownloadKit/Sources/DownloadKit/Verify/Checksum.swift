import CryptoKit
import Foundation
import Synchronization

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public struct Checksum: Codable, Sendable, Equatable {
    public enum Algorithm: String, Codable, Sendable, CaseIterable {
        case sha256, md5

        public var hexLength: Int { self == .sha256 ? 64 : 32 }
    }

    public var algorithm: Algorithm
    /// Lowercase hex digest.
    public var hex: String

    public init(algorithm: Algorithm, hex: String) {
        self.algorithm = algorithm
        self.hex = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Accepts `sha256:<hex>`, `md5:<hex>`, or a bare digest whose length identifies the algorithm.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        let candidate: Checksum
        if parts.count == 2, let algorithm = Algorithm(rawValue: parts[0].lowercased()) {
            candidate = Checksum(algorithm: algorithm, hex: parts[1])
        } else if let algorithm = Algorithm.allCases.first(where: { $0.hexLength == trimmed.count }) {
            candidate = Checksum(algorithm: algorithm, hex: trimmed)
        } else {
            return nil
        }
        guard candidate.isWellFormed else { return nil }
        self = candidate
    }

    public var isWellFormed: Bool {
        hex.count == algorithm.hexLength && hex.allSatisfy { $0.isHexDigit }
    }
}

public enum ChecksumVerifier {
    /// Streams the file through the hash on a background queue. `progress` receives bytes hashed so far.
    public static func digest(
        of fileURL: URL,
        algorithm: Checksum.Algorithm,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> String {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let isCancelled: @Sendable () -> Bool = { cancelled.withLock { $0 } }
                    do {
                        let hex = switch algorithm {
                        case .sha256: try hash(SHA256(), fileURL, progress, isCancelled)
                        case .md5: try hash(Insecure.MD5(), fileURL, progress, isCancelled)
                        }
                        continuation.resume(returning: hex)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func hash<H: HashFunction>(
        _ initial: H,
        _ url: URL,
        _ progress: (@Sendable (Int64) -> Void)?,
        _ isCancelled: @Sendable () -> Bool
    ) throws -> String {
        var hasher = initial
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            progress?(total)
        }
        return hasher.finalize().hexString
    }
}
