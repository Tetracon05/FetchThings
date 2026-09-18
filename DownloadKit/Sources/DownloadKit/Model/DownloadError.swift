import Foundation

public enum DownloadError: Error, Sendable, Equatable {
    case unsupportedURL(String)
    case invalidOption(String)
    case httpStatus(Int, retryAfter: TimeInterval?)
    /// Raw value of a `URLError.Code`.
    case network(Int)
    case rangeNotHonored
    case invalidRangeResponse(String)
    case resourceChanged
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case fileSystem(String)
    case checksumMismatch(expected: String, actual: String)
    case shortRead
    case unsafeDestination(String)

    /// Whether a fresh attempt of the same request may succeed.
    public var isRetryable: Bool {
        switch self {
        case .httpStatus(let code, _):
            code == 408 || code == 425 || code == 429 || (500...599).contains(code) && code != 501 && code != 505
        case .network(let raw):
            Self.retryableURLErrors.contains(raw)
        case .shortRead:
            true
        default:
            false
        }
    }

    var retryAfter: TimeInterval? {
        if case .httpStatus(_, let after) = self { after } else { nil }
    }

    private static let retryableURLErrors: Set<Int> = [
        URLError.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .dataNotAllowed,
        .internationalRoamingOff, .badServerResponse, .cannotParseResponse, .callIsActive,
    ].reduce(into: Set<Int>()) { $0.insert($1.rawValue) }
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let why): "Unsupported URL: \(why)"
        case .invalidOption(let why): "Invalid option: \(why)"
        case .httpStatus(let code, _): "The server responded with HTTP \(code) (\(HTTPURLResponse.localizedString(forStatusCode: code)))."
        case .network(let raw): URLError(URLError.Code(rawValue: raw)).localizedDescription
        case .rangeNotHonored: "The server ignored the byte-range request."
        case .invalidRangeResponse(let why): "Unexpected range response: \(why)"
        case .resourceChanged: "The file changed on the server during the download."
        case .insufficientDiskSpace(let needed, let available):
            "Not enough disk space (\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed, "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available)."
        case .fileSystem(let why): "File error: \(why)"
        case .checksumMismatch(let expected, let actual): "Checksum mismatch (expected \(expected), got \(actual))."
        case .shortRead: "The connection closed before all data arrived."
        case .unsafeDestination(let why): "Unsafe destination: \(why)"
        }
    }
}

extension DownloadError {
    /// A file-system failure described by an `errno` value. Capture `errno` before making any other
    /// system call, since those can overwrite it.
    static func posix(_ action: String, _ code: Int32) -> DownloadError {
        .fileSystem("\(action): \(String(cString: strerror(code)))")
    }

    /// Translates whatever URLSession or the file layer threw into the engine's vocabulary.
    /// Cancellation stays a `CancellationError` so callers can tell a stop from a failure.
    static func map(_ error: Error) -> Error {
        if error is DownloadError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : DownloadError.network(urlError.code.rawValue)
        }
        return DownloadError.fileSystem(error.localizedDescription)
    }
}
