import Foundation
import Testing
@testable import DownloadKit

@Suite("Prober")
struct ProberTests {
    private func probe(_ server: MockHTTPServer, path: String = "/file.bin") async throws -> ProbeResult {
        let context = RequestContext(url: server.url(path), options: .init(), sensitive: .init(), defaultUserAgent: nil, timeout: 10)
        return try await Prober(context: context).probe()
    }

    @Test func headSuppliesSizeRangesFilenameAndValidators() async throws {
        let resource = MockResource(size: 123_456, contentDisposition: #"attachment; filename="data set.zip""#)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }

        let result = try await probe(server)
        #expect(result.contentLength == 123_456)
        #expect(result.acceptsRanges)
        #expect(result.suggestedFilename == "data set.zip")
        #expect(result.etag == "\"v1\"")
        #expect(result.lastModified == resource.lastModified)
        #expect(server.requests.map(\.method) == ["HEAD"], "a complete HEAD answer needs no second request")
    }

    @Test func fallsBackToARangeGetWhenHeadIsRejected() async throws {
        let resource = MockResource(size: 50_000, supportsHEAD: false)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }

        let result = try await probe(server)
        #expect(result.contentLength == 50_000)
        #expect(result.acceptsRanges)
        let methods = server.requests.map(\.method)
        #expect(methods == ["HEAD", "GET"])
        #expect(server.requests.last?.headers["range"] == "bytes=0-0")
        #expect(server.bodyBytesSent <= 1, "the probe must never pull the file body")
    }

    @Test func confirmsRangesWithAGetWhenTheHeaderIsMissing() async throws {
        // Plenty of servers honor Range without announcing it.
        let resource = MockResource(size: 20_000, advertisesRanges: false)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }

        let result = try await probe(server)
        #expect(result.acceptsRanges)
        #expect(result.contentLength == 20_000)
    }

    @Test func detectsServersThatIgnoreRange() async throws {
        let resource = MockResource(size: 20_000, honorsRange: false, advertisesRanges: false)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }

        let result = try await probe(server)
        #expect(!result.acceptsRanges)
        #expect(result.contentLength == 20_000)
    }

    @Test func aServerThatLiesAboutRangesIsCaughtAtDownloadTimeNotProbeTime() async throws {
        // Advertises ranges on HEAD but answers ranged GETs with 200. The probe believes the header.
        let resource = MockResource(size: 20_000, honorsRange: false, advertisesRanges: true)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }
        #expect(try await probe(server).acceptsRanges)
    }

    @Test func emptyFilesAreHandled() async throws {
        let resource = MockResource(size: 0, advertisesRanges: false)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }
        defer { server.stop() }
        let result = try await probe(server)
        #expect(result.contentLength == 0)
    }

    @Test func reportsHTTPErrorsWithTheirStatus() async throws {
        let server = try await MockHTTPServer.start { _ in .status(404) }
        defer { server.stop() }
        await #expect(throws: DownloadError.httpStatus(404, retryAfter: nil)) { try await probe(server) }
    }

    @Test func surfacesRetryAfter() async throws {
        let server = try await MockHTTPServer.start { _ in .status(503, headers: [("Retry-After", "7")]) }
        defer { server.stop() }
        await #expect(throws: DownloadError.httpStatus(503, retryAfter: 7)) { try await probe(server) }
    }

    @Test func aConnectionRefusedIsANetworkError() async throws {
        let server = try await MockHTTPServer.start { _ in .status(200) }
        let url = server.url()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let context = RequestContext(url: url, options: .init(), sensitive: .init(), defaultUserAgent: nil, timeout: 5)
        await #expect(throws: DownloadError.self) { try await Prober(context: context).probe() }
    }

    @Test func compressedResponsesAreNotTreatedAsRangeable() async throws {
        let server = try await MockHTTPServer.start { request in
            var response = MockResource(size: 1000).response(for: request)
            response.headers.append(("Content-Encoding", "gzip"))
            return response
        }
        defer { server.stop() }
        let result = try await probe(server)
        #expect(!result.acceptsRanges)
        #expect(result.contentLength == nil, "a compressed Content-Length does not describe the decoded bytes")
    }
}
