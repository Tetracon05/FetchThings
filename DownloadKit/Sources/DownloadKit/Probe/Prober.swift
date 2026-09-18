import Foundation

struct ProbeResult: Sendable, Equatable {
    var finalURL: URL
    /// `nil` when the server does not say.
    var contentLength: Int64?
    var acceptsRanges: Bool
    /// Already sanitized.
    var suggestedFilename: String
    var mimeType: String?
    var etag: String?
    var lastModified: String?

    var validators: Validators { Validators(etag: etag, lastModified: lastModified) }
}

/// Learns size, range support, filename and validators before any bytes are downloaded.
///
/// A HEAD request is tried first. Range support is only believed once the server has said so
/// (`Accept-Ranges: bytes`); otherwise a `Range: bytes=0-0` GET settles it, since many servers reject
/// HEAD or omit the header while honoring ranges.
struct Prober: Sendable {
    let context: RequestContext

    func probe() async throws -> ProbeResult {
        let session = URLSession(configuration: RequestContext.sessionConfiguration(timeout: context.timeout))
        defer { session.finishTasksAndInvalidate() }

        var head: ProbeResult?
        do {
            head = try await headProbe(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            head = nil
        }
        if let head, head.acceptsRanges, head.contentLength != nil { return head }

        var result: ProbeResult
        do {
            result = try await rangeProbe(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // HEAD worked but the confirming Range GET did not (a server or WAF that rejects Range, or a
            // transient error). A plain GET may still succeed, so download over one connection.
            guard var fallback = head else { throw error }
            fallback.acceptsRanges = false
            return fallback
        }
        if result.contentLength == nil { result.contentLength = head?.contentLength }
        return result
    }

    private func headProbe(_ session: URLSession) async throws -> ProbeResult? {
        do {
            let request = context.urlRequest(method: "HEAD")
            let (_, response) = try await session.data(for: request, delegate: RedirectGuard(original: request))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
            let encoded = HTTPHeaders.hasContentEncoding(http)
            return describe(http, length: encoded ? nil : length, acceptsRanges: ranges && !encoded)
        } catch {
            throw DownloadError.map(error)
        }
    }

    private func rangeProbe(_ session: URLSession) async throws -> ProbeResult {
        do {
            let request = context.urlRequest(range: (0, 0))
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard(original: request))
            // Headers are all we need; never pull a whole file through a probe.
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidRangeResponse("not an HTTP response") }

            switch http.statusCode {
            case 206:
                let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPHeaders.parseContentRange)
                let encoded = HTTPHeaders.hasContentEncoding(http)
                return describe(http, length: encoded ? nil : range?.total, acceptsRanges: !encoded && range?.start == 0)
            case 200:
                let encoded = HTTPHeaders.hasContentEncoding(http)
                let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
                return describe(http, length: encoded ? nil : length, acceptsRanges: false)
            case 416:
                // Range 0-0 of an empty resource is unsatisfiable: `Content-Range: bytes */0`.
                if let total = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPHeaders.parseContentRange)?.total, total == 0 {
                    return describe(http, length: 0, acceptsRanges: true)
                }
                throw HTTPHeaders.statusError(http)
            default:
                throw HTTPHeaders.statusError(http)
            }
        } catch {
            throw DownloadError.map(error)
        }
    }

    private func describe(_ http: HTTPURLResponse, length: Int64?, acceptsRanges: Bool) -> ProbeResult {
        ProbeResult(
            finalURL: http.url ?? context.url,
            contentLength: length,
            acceptsRanges: acceptsRanges,
            suggestedFilename: FilenameResolver.suggest(
                contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                finalURL: http.url,
                originalURL: context.url,
                mimeType: http.value(forHTTPHeaderField: "Content-Type")
            ),
            mimeType: http.value(forHTTPHeaderField: "Content-Type"),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}
