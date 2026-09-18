import Foundation

/// What must stay the same for a partial download to remain valid.
struct Validators: Sendable, Equatable {
    var etag: String?
    var lastModified: String?

    /// Value for `If-Range`: only a strong ETag or a date is allowed there.
    var ifRange: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        return lastModified
    }

    /// `false` only when both sides carry a validator and they disagree.
    func matches(etag otherETag: String?, lastModified otherModified: String?) -> Bool {
        if let etag, let otherETag { return Self.strip(etag) == Self.strip(otherETag) }
        if let lastModified, let otherModified { return lastModified == otherModified }
        return true
    }

    private static func strip(_ tag: String) -> String { tag.hasPrefix("W/") ? String(tag.dropFirst(2)) : tag }
}

enum HTTPHeaders {
    struct ContentRange: Equatable {
        var start: Int64?
        var end: Int64?
        var total: Int64?
    }

    /// `bytes 0-99/1000`, `bytes 0-99/*`, or the unsatisfied form `bytes */1000`.
    static func parseContentRange(_ value: String) -> ContentRange? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let halves = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let total = halves[1] == "*" ? nil : Int64(halves[1])
        if halves[0] == "*" { return ContentRange(start: nil, end: nil, total: total) }
        let bounds = halves[0].split(separator: "-", maxSplits: 1).compactMap { Int64($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        return ContentRange(start: bounds[0], end: bounds[1], total: total)
    }

    /// Seconds, or an HTTP date relative to `now`.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func hasContentEncoding(_ response: HTTPURLResponse) -> Bool {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() else { return false }
        return !encoding.isEmpty && encoding != "identity"
    }

    static func statusError(_ response: HTTPURLResponse) -> DownloadError {
        .httpStatus(response.statusCode, retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After")))
    }
}
