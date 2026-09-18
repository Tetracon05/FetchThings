import Foundation

/// Everything needed to build a request for one download. Holds secrets, so it is never persisted.
struct RequestContext: Sendable {
    var url: URL
    var options: DownloadOptions
    var sensitive: SensitiveOptions
    var defaultUserAgent: String?
    var timeout: TimeInterval

    /// Headers the engine owns; a user-supplied value for these is dropped.
    static let reservedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer",
        "range", "if-range", "accept-encoding", "proxy-authorization", "expect",
    ]

    static func validate(url: URL, options: DownloadOptions, sensitive: SensitiveOptions) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedURL("only http and https URLs can be downloaded")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw DownloadError.unsupportedURL("missing host")
        }
        if let count = options.segmentCount, !(1...64).contains(count) {
            throw DownloadError.invalidOption("segment count must be between 1 and 64")
        }
        if let limit = options.speedLimit, limit <= 0 {
            throw DownloadError.invalidOption("speed limit must be positive")
        }
        if let retries = options.maxRetries, !(0...100).contains(retries) {
            throw DownloadError.invalidOption("retries must be between 0 and 100")
        }
        if let referer = options.referer, !["http", "https"].contains(referer.scheme?.lowercased() ?? "") {
            throw DownloadError.invalidOption("referer must be an http(s) URL")
        }
        if let checksum = options.checksum, !checksum.isWellFormed {
            throw DownloadError.invalidOption("malformed checksum")
        }
        if let agent = options.userAgent { try requireSingleLine(agent, "user agent") }
        if let cookies = sensitive.cookies { try requireSingleLine(cookies, "cookies") }
        for (name, value) in sensitive.headers {
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil else {
                throw DownloadError.invalidOption("invalid header name \"\(name)\"")
            }
            try requireSingleLine(value, "header \(name)")
        }
        if let auth = sensitive.basicAuth {
            guard !auth.username.contains(":") else {
                throw DownloadError.invalidOption("a Basic-auth user name cannot contain a colon")
            }
        }
    }

    private static func requireSingleLine(_ value: String, _ what: String) throws {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) || value.utf8.count > 8192 {
            throw DownloadError.invalidOption("\(what) contains control characters or is too long")
        }
    }

    /// Requests take their headers only from here; nothing is inherited from a shared cookie jar or
    /// credential store.
    func urlRequest(method: String = "GET", range: (start: Int64, end: Int64?)? = nil, ifRange: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for (name, value) in sensitive.headers where !Self.reservedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let agent = options.userAgent ?? defaultUserAgent {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let referer = options.referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookies = sensitive.cookies {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        if let auth = sensitive.basicAuth {
            let token = Data("\(auth.username):\(auth.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        // A compressed body would make Content-Length and ranges describe different things.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            request.setValue("bytes=\(range.start)-\(range.end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
            if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        }
        return request
    }

    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }
}
