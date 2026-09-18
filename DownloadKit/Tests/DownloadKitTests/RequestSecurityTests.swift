import Foundation
import Testing
@testable import DownloadKit

@Suite("Requests and redirects")
struct RequestSecurityTests {
    private func context(
        url: String = "https://example.com/f.bin",
        options: DownloadOptions = .init(),
        sensitive: SensitiveOptions = .init()
    ) -> RequestContext {
        RequestContext(url: URL(string: url)!, options: options, sensitive: sensitive, defaultUserAgent: nil, timeout: 30)
    }

    // MARK: Building requests

    @Test func appliesTheDocumentedHeaders() {
        let request = context(
            options: DownloadOptions(referer: URL(string: "https://ref.example/page"), userAgent: "TestAgent/1.0"),
            sensitive: SensitiveOptions(cookies: "session=abc; theme=dark", headers: ["X-Token": "t0k"], basicAuth: BasicAuth(username: "ann", password: "s3cret"))
        ).urlRequest()
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc; theme=dark")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://ref.example/page")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
        #expect(request.value(forHTTPHeaderField: "X-Token") == "t0k")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("ann:s3cret".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func formatsRangeRequests() {
        let bounded = context().urlRequest(range: (100, 199), ifRange: "\"abc\"")
        #expect(bounded.value(forHTTPHeaderField: "Range") == "bytes=100-199")
        #expect(bounded.value(forHTTPHeaderField: "If-Range") == "\"abc\"")
        #expect(context().urlRequest(range: (5, nil)).value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(context().urlRequest().value(forHTTPHeaderField: "Range") == nil)
    }

    @Test func userHeadersCannotOverrideEngineOwnedOnes() {
        let request = context(sensitive: SensitiveOptions(headers: [
            "Range": "bytes=0-1", "Host": "evil.example", "Accept-Encoding": "gzip", "Content-Length": "9", "If-Range": "x",
        ])).urlRequest(range: (10, 20))
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-20")
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(request.value(forHTTPHeaderField: "If-Range") == nil)
    }

    // MARK: Validation

    @Test(arguments: ["file:///etc/passwd", "ftp://example.com/a", "javascript:alert(1)", "data:text/plain,hi", "http:///nohost"])
    func rejectsNonHTTPURLs(url: String) {
        #expect(throws: DownloadError.self) {
            try RequestContext.validate(url: URL(string: url)!, options: .init(), sensitive: .init())
        }
    }

    @Test func rejectsHeaderInjection() {
        let url = URL(string: "https://example.com/")!
        let bad: [SensitiveOptions] = [
            SensitiveOptions(cookies: "a=b\r\nX-Injected: 1"),
            SensitiveOptions(headers: ["X-A": "v\r\nX-B: 1"]),
            SensitiveOptions(headers: ["X A": "v"]),
            SensitiveOptions(headers: ["X-A:": "v"]),
            SensitiveOptions(headers: ["": "v"]),
            SensitiveOptions(basicAuth: BasicAuth(username: "a:b", password: "x")),
        ]
        for sensitive in bad {
            #expect(throws: DownloadError.self) { try RequestContext.validate(url: url, options: .init(), sensitive: sensitive) }
        }
        #expect(throws: DownloadError.self) {
            try RequestContext.validate(url: url, options: DownloadOptions(userAgent: "x\ny"), sensitive: .init())
        }
    }

    @Test func rejectsOutOfRangeOptions() {
        let url = URL(string: "https://example.com/")!
        for options in [DownloadOptions(segmentCount: 0), DownloadOptions(segmentCount: 65), DownloadOptions(speedLimit: 0), DownloadOptions(maxRetries: -1), DownloadOptions(checksum: Checksum(algorithm: .sha256, hex: "abc"))] {
            #expect(throws: DownloadError.self) { try RequestContext.validate(url: url, options: options, sensitive: .init()) }
        }
        #expect(throws: Never.self) {
            try RequestContext.validate(url: url, options: DownloadOptions(segmentCount: 8, speedLimit: 1), sensitive: SensitiveOptions(cookies: "a=b"))
        }
    }

    // MARK: Redirects

    /// `original` is the request the user configured; `arriving` is what URLSession proposes to send.
    private func redirect(
        originalURL: String, to target: String,
        original: [String: String], arriving: [String: String]
    ) -> URLRequest? {
        var configured = URLRequest(url: URL(string: originalURL)!)
        for (name, value) in original { configured.setValue(value, forHTTPHeaderField: name) }
        var proposed = URLRequest(url: URL(string: target)!)
        for (name, value) in arriving { proposed.setValue(value, forHTTPHeaderField: name) }
        return RedirectPolicy.sanitize(proposed, trusting: configured)
    }

    private let credentialed = [
        "Authorization": "Basic c2VjcmV0", "Cookie": "session=abc", "X-Api-Key": "k", "Range": "bytes=0-9",
        "User-Agent": "UA", "Referer": "https://ref.example/", "Accept-Encoding": "identity", "If-Range": "\"e\"",
    ]

    @Test func sameOriginRedirectRestoresWhatURLSessionDropped() {
        // URLSession removes Authorization on every redirect, even to the same host.
        var arriving = credentialed
        arriving["Authorization"] = nil
        let result = redirect(originalURL: "https://example.com/a", to: "https://example.com/b", original: credentialed, arriving: arriving)
        #expect(result?.allHTTPHeaderFields == credentialed)
    }

    @Test func aRedirectKeepsItsOwnRangeEvenWhenTheOriginalDiffers() {
        var arriving = credentialed
        arriving["Range"] = "bytes=500-999"
        let result = redirect(originalURL: "https://example.com/a", to: "https://example.com/b", original: credentialed, arriving: arriving)
        #expect(result?.value(forHTTPHeaderField: "Range") == "bytes=500-999")
        #expect(result?.value(forHTTPHeaderField: "Authorization") == "Basic c2VjcmV0")
    }

    @Test(arguments: [
        ("https://example.com/a", "https://cdn.example.net/b"),   // other host
        ("https://example.com/a", "https://sub.example.com/b"),   // subdomain is another origin
        ("https://example.com/a", "http://example.com/b"),        // scheme downgrade
        ("https://example.com/a", "https://example.com:8443/b"),  // other port
        ("http://127.0.0.1:8000/a", "http://127.0.0.1:9000/b"),
    ])
    func crossOriginRedirectDropsCredentials(source: String, target: String) throws {
        // Worst case: URLSession proposes to carry everything.
        let result = try #require(redirect(originalURL: source, to: target, original: credentialed, arriving: credentialed))
        let names = Set((result.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(!names.contains("authorization"))
        #expect(!names.contains("cookie"))
        #expect(!names.contains("x-api-key"))
        // What the transfer needs to continue safely still travels.
        #expect(names.isSuperset(of: ["range", "if-range", "user-agent", "accept-encoding"]))
    }

    @Test func returningToTheNamedOriginAfterAHopGetsCredentialsBack() throws {
        // A -> B strips; B -> A must not leave the request permanently stripped.
        let hop = try #require(redirect(originalURL: "https://a.example/x", to: "https://b.example/y", original: credentialed, arriving: credentialed))
        #expect(hop.value(forHTTPHeaderField: "Authorization") == nil)
        let back = redirect(originalURL: "https://a.example/x", to: "https://a.example/z", original: credentialed, arriving: hop.allHTTPHeaderFields ?? [:])
        #expect(back?.value(forHTTPHeaderField: "Authorization") == "Basic c2VjcmV0")
    }

    @Test func defaultPortsCompareEqual() {
        let result = redirect(originalURL: "https://example.com/a", to: "https://example.com:443/b", original: credentialed, arriving: [:])
        #expect(result?.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test(arguments: ["file:///etc/passwd", "ftp://example.com/x", "javascript:alert(1)"])
    func refusesRedirectsToOtherSchemes(target: String) {
        #expect(redirect(originalURL: "https://example.com/a", to: target, original: credentialed, arriving: credentialed) == nil)
    }

    @Test func quarantineRecordsTheOriginWithoutItsCredentials() {
        let properties = DestinationResolver.quarantineProperties(origin: URL(string: "https://ann:hunter2@example.com/a/b.zip?x=1")!, agent: "Downloader")
        let recorded = properties["LSQuarantineDataURL"] as? String
        #expect(recorded == "https://example.com/a/b.zip?x=1")
        #expect(properties["LSQuarantineType"] as? String == "LSQuarantineTypeWebDownload")
    }
}

@Suite("HTTP header parsing")
struct HeaderParsingTests {
    @Test func parsesContentRange() {
        #expect(HTTPHeaders.parseContentRange("bytes 0-99/1000") == .init(start: 0, end: 99, total: 1000))
        #expect(HTTPHeaders.parseContentRange("bytes 5-5/*") == .init(start: 5, end: 5, total: nil))
        #expect(HTTPHeaders.parseContentRange("bytes */0") == .init(start: nil, end: nil, total: 0))
        #expect(HTTPHeaders.parseContentRange("BYTES 1-2/3") == .init(start: 1, end: 2, total: 3))
        for bad in ["", "bytes", "bytes 9-1/10", "items 0-1/2", "bytes a-b/c", "bytes 0-1"] {
            #expect(HTTPHeaders.parseContentRange(bad) == nil, "\(bad)")
        }
    }

    @Test func parsesRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HTTPHeaders.parseRetryAfter("120", now: now) == 120)
        #expect(HTTPHeaders.parseRetryAfter("-5", now: now) == 0)
        #expect(HTTPHeaders.parseRetryAfter(nil, now: now) == nil)
        #expect(HTTPHeaders.parseRetryAfter("soon", now: now) == nil)
        // 2023-11-14 22:15:00 GMT is 100 s after `now` (22:13:20).
        #expect(HTTPHeaders.parseRetryAfter("Tue, 14 Nov 2023 22:15:00 GMT", now: now) == 100)
    }

    @Test func etagValidatorsCompare() {
        let v = Validators(etag: "\"a\"", lastModified: nil)
        #expect(v.matches(etag: "\"a\"", lastModified: nil))
        #expect(v.matches(etag: "W/\"a\"", lastModified: nil), "weak and strong forms of the same tag match")
        #expect(!v.matches(etag: "\"b\"", lastModified: nil))
        #expect(v.matches(etag: nil, lastModified: "x"), "no validator on one side means nothing to compare")
        #expect(!Validators(etag: nil, lastModified: "d1").matches(etag: nil, lastModified: "d2"))
        #expect(Validators(etag: "W/\"a\"", lastModified: "d").ifRange == "d", "a weak ETag is not allowed in If-Range")
        #expect(Validators(etag: "\"a\"", lastModified: "d").ifRange == "\"a\"")
    }
}
