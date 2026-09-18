import Foundation
import Synchronization
import Testing
@testable import DownloadKit

@Suite("Downloading", .serialized)
struct DownloadIntegrationTests {
    @Test func segmentedDownloadReproducesTheFileOverParallelConnections() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 4 * 1024 * 1024, bytesPerSecond: 4_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.mode == .segmented)
        #expect(done.totalBytes == Int64(resource.size))
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(!FileManager.default.fileExists(atPath: env.file("file.bin.part").path), "the .part file is renamed on completion")
        #expect(server.maxConcurrentConnections >= 4, "segments must really use separate connections (saw \(server.maxConcurrentConnections))")
        #expect(server.dataRequests.allSatisfy { $0.headers["range"] != nil })
        #expect(done.finalURL?.lastPathComponent == "file.bin")
    }

    @Test func oneSegmentIsJustASingleConnection() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed)
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(server.dataRequests.count == 1)
        #expect(server.dataRequests.first?.headers["range"] == "bytes=0-999999")
        #expect(server.maxConcurrentConnections == 1)
    }

    @Test func serverWithoutRangeSupportDownloadsOverOneConnection() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 3 * 1024 * 1024, honorsRange: false, advertisesRanges: false)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 8))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.mode == .single)
        #expect(!done.supportsResume)
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(server.dataRequests.count == 1)
        #expect(server.dataRequests.first?.headers["range"] == nil)
    }

    @Test func aServerThatAdvertisesButIgnoresRangesFallsBackMidDownload() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 2 * 1024 * 1024, honorsRange: false, advertisesRanges: true)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.mode == .single)
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test func downloadsFilesOfUnknownLength() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let data = MockContent.data(seed: 4, length: 700_000)
        let server = try await MockHTTPServer.start { request in
            request.method == "HEAD" ? .status(405) : MockResponse(status: 200, body: .data(data), omitContentLength: true)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url("/stream"), segments: 4))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.mode == .single)
        #expect(try Data(contentsOf: env.file("stream")) == data)
    }

    @Test func emptyFilesComplete() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 0)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try Data(contentsOf: env.file("file.bin")).isEmpty)
    }

    @Test func idleConnectionsStealWorkFromTheSlowestSegment() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 1024 * 1024
        let resource = MockResource(size: size)
        // The request for the first half crawls; the second half is instant.
        let server = try await MockHTTPServer.start { request in
            var response = resource.response(for: request)
            if request.method == "GET", request.range?.start == 0 { response.bytesPerSecond = 300_000 }
            return response
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        let starts = server.dataRequests.compactMap { $0.range?.start }.sorted()
        #expect(starts.count >= 3, "a third request means the finished connection took over part of the slow range: \(starts)")
        #expect(starts.contains { $0 > 0 && $0 < size / 2 }, "the stolen range starts inside the slow segment: \(starts)")
    }

    // MARK: Failure handling

    @Test func retriesTransientServerErrors() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 800_000)
        let failures = Counter()
        let server = try await MockHTTPServer.start { request in
            if request.method == "GET", request.headers["range"] != "bytes=0-0", failures.next() <= 3 {
                return .status(503, headers: [("Retry-After", "0")])
            }
            return resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(failures.current >= 5, "three failed attempts plus the successful ones")
    }

    @Test func resumesFromTheByteWhereAConnectionDropped() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 600_000
        let resource = MockResource(size: size)
        let drops = Counter()
        let server = try await MockHTTPServer.start { request in
            var response = resource.response(for: request)
            if request.method == "GET", request.headers["range"] != "bytes=0-0", drops.next() <= 4 { response.dropAfterBodyBytes = 100_000 }
            return response
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        let starts = server.dataRequests.compactMap { $0.range?.start }
        #expect(starts.first == 0)
        #expect(starts.dropFirst().allSatisfy { $0 > 0 }, "retries continue where the data stopped, not from zero: \(starts)")
        #expect(server.bodyBytesSent < size * 3 / 2, "no large re-download (sent \(server.bodyBytesSent) for \(size))")
    }

    @Test func doesNotRetryPermanentErrors() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let server = try await MockHTTPServer.start { request in
            request.method == "GET" && request.headers["range"] != "bytes=0-0" ? .status(403) : resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("403") == true, "\(done.failure ?? "")")
        #expect(server.dataRequests.count == 1, "a 403 is final")
    }

    @Test func givesUpWhenTheRetryBudgetIsSpent() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let server = try await MockHTTPServer.start { request in
            request.method == "GET" && request.headers["range"] != "bytes=0-0" ? .status(503) : resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { $0.options.maxRetries = 2 })
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("503") == true)
        #expect(server.dataRequests.count == 3, "one attempt plus two retries")
        #expect(!FileManager.default.fileExists(atPath: env.file("file.bin").path))
    }

    @Test func aFailedDownloadCanBeRetried() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let healthy = Mutex(false)
        let server = try await MockHTTPServer.start { request in
            if !healthy.withLock({ $0 }), request.method == "GET", request.headers["range"] != "bytes=0-0" { return .status(404) }
            return resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        #expect(await waitForCompletion(manager, id).state == .failed)

        healthy.withLock { $0 = true }
        await manager.resume(id)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test func refusesToStartWhenTheDiskCannotHoldTheFile() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000_000_000_000) // 200 TB, only ever asked for via HEAD
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("disk space") == true, "\(done.failure ?? "")")
        #expect(server.dataRequests.isEmpty)
    }

    @Test func rejectsUnsupportedRequestsWithoutPersistingAnything() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let manager = env.makeManager()
        await #expect(throws: DownloadError.self) { try await manager.add(env.newDownload(URL(string: "file:///etc/passwd")!)) }
        await #expect(throws: DownloadError.self) { try await manager.add(env.newDownload(URL(string: "https://example.com/x")!, segments: 999)) }
        await #expect(throws: DownloadError.self) {
            try await manager.add(env.newDownload(URL(string: "https://example.com/x")!) { $0.sensitive.cookies = "a=b\r\nInjected: 1" })
        }
        #expect(await manager.allSnapshots().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: env.jobs.path))?.isEmpty ?? true)
    }

    // MARK: Verification

    @Test func verifiesSHA256AndMD5() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 300_000)
        let content = MockContent.data(seed: resource.seed, length: resource.size)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let md5 = try await ChecksumVerifier.digest(of: writeTemp(content, in: env), algorithm: .md5)
        let sha = sha256Hex(of: content)

        let a = try await manager.add(env.newDownload(server.url("/a.bin"), segments: 2) { $0.options.checksum = Checksum(algorithm: .sha256, hex: sha) })
        let b = try await manager.add(env.newDownload(server.url("/b.bin"), segments: 2) { $0.options.checksum = Checksum(algorithm: .md5, hex: md5.uppercased()) })
        for id in [a, b] {
            let done = await waitForCompletion(manager, id)
            #expect(done.state == .completed, "\(done.failure ?? "")")
            #expect(done.checksumVerified == true)
        }
    }

    @Test func aChecksumMismatchFailsAndLeavesNoFile() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 300_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let wrong = Checksum(algorithm: .sha256, hex: String(repeating: "0", count: 64))
        let id = try await manager.add(env.newDownload(server.url(), segments: 2) { $0.options.checksum = wrong })
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("Checksum mismatch") == true, "\(done.failure ?? "")")
        #expect(done.checksumVerified != true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.downloads.path)
        #expect(leftovers.isEmpty, "neither the corrupt file nor its .part may remain: \(leftovers)")
    }

    private func writeTemp(_ data: Data, in env: TestEnvironment) throws -> URL {
        let url = env.root.appending(path: "reference.bin")
        try data.write(to: url)
        return url
    }
}
