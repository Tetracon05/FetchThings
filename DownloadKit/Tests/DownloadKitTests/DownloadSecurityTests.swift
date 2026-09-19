import Foundation
import Synchronization
import Testing
@testable import DownloadKit

@Suite("Credentials, paths and secrets", .serialized)
struct DownloadSecurityTests {
    private func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    // MARK: Per-download request settings

    @Test func sendsCookiesRefererUserAgentHeadersAndBasicAuth() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let expected = basic("ann", "s3cret")
        let server = try await MockHTTPServer.start { request in
            request.headers["authorization"] == expected ? resource.response(for: request) : .status(401, headers: [("WWW-Authenticate", "Basic realm=\"t\"")])
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2) { request in
            request.options.userAgent = "TestAgent/1.0"
            request.options.referer = URL(string: "https://origin.example/page")
            request.sensitive = SensitiveOptions(cookies: "session=abc; theme=dark", headers: ["X-Token": "t0k"], basicAuth: BasicAuth(username: "ann", password: "s3cret"))
        })
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(!server.requests.isEmpty)
        for request in server.requests {
            #expect(request.headers["cookie"] == "session=abc; theme=dark", "\(request.method) \(request.headers)")
            #expect(request.headers["referer"] == "https://origin.example/page")
            #expect(request.headers["user-agent"] == "TestAgent/1.0")
            #expect(request.headers["x-token"] == "t0k")
            #expect(request.headers["authorization"] == expected)
        }
    }

    @Test func missingCredentialsFailWithoutRetrying() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let server = try await MockHTTPServer.start { _ in .status(401, headers: [("WWW-Authenticate", "Basic realm=\"t\"")]) }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .failed)
        #expect(done.failure?.contains("401") == true, "\(done.failure ?? "")")
    }

    @Test func credentialsInTheURLAreMovedOutOfTheStoredRecord() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let expected = basic("ann", "pw-in-url-123")
        let server = try await MockHTTPServer.start { request in
            request.headers["authorization"] == expected ? resource.response(for: request) : .status(401)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let url = URL(string: "http://ann:pw-in-url-123@127.0.0.1:\(server.port)/file.bin")!
        let id = try await manager.add(env.newDownload(url, segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(!done.url.absoluteString.contains("pw-in-url-123") && done.url.user == nil)
        #expect(try filesContaining("pw-in-url-123", under: env.root).isEmpty, "the password reached the disk")
    }

    @Test func cookiesHeadersAndPasswordsNeverReachTheJobStore() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 80_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { request in
            request.sensitive = SensitiveOptions(cookies: "session=TOPSECRETCOOKIE", headers: ["Authorization": "Bearer TOPSECRETBEARER"], basicAuth: BasicAuth(username: "u", password: "TOPSECRETPASSWORD"))
        })
        #expect(await waitForCompletion(manager, id).state == .completed)

        for secret in ["TOPSECRETCOOKIE", "TOPSECRETBEARER", "TOPSECRETPASSWORD"] {
            #expect(try filesContaining(secret, under: env.root).isEmpty, "\(secret) was written to disk")
        }
        // ...and they are wiped when the download is removed.
        await manager.remove(id)
        #expect(await env.secrets.secrets(for: id) == nil)
    }

    // MARK: Redirects

    @Test func credentialsStayWithTheOriginTheUserNamed() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 150_000)
        let target = try await MockHTTPServer.start { resource.response(for: $0) }; defer { target.stop() }
        let origin = try await MockHTTPServer.start { _ in
            .status(302, headers: [("Location", target.url("/file.bin").absoluteString)])
        }
        defer { origin.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(origin.url("/get"), segments: 2) { request in
            request.options.userAgent = "TestAgent/1.0"
            request.sensitive = SensitiveOptions(cookies: "session=abc", headers: ["X-Api-Key": "key123"], basicAuth: BasicAuth(username: "ann", password: "pw"))
        })
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource), "the file name comes from the redirect target")
        #expect(origin.requests.allSatisfy { $0.headers["authorization"] != nil && $0.headers["cookie"] != nil && $0.headers["x-api-key"] != nil })
        #expect(!target.requests.isEmpty)
        for request in target.requests {
            #expect(request.headers["authorization"] == nil, "Authorization leaked to another origin")
            #expect(request.headers["cookie"] == nil, "Cookie leaked to another origin")
            #expect(request.headers["x-api-key"] == nil, "custom header leaked to another origin")
            #expect(request.headers["user-agent"] == "TestAgent/1.0")
        }
        #expect(target.dataRequests.allSatisfy { $0.headers["range"] != nil }, "ranges must survive the redirect")
    }

    @Test func sameOriginRedirectsKeepCredentials() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let expected = basic("ann", "pw")
        let server = try await MockHTTPServer.start { request in
            guard request.headers["authorization"] == expected else { return .status(401) }
            return request.path == "/start" ? .status(302, headers: [("Location", "/final.bin")]) : resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url("/start"), segments: 1) { $0.sensitive.basicAuth = BasicAuth(username: "ann", password: "pw") })
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
    }

    @Test func redirectsToNonHTTPSchemesAreRefused() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let server = try await MockHTTPServer.start { _ in .status(302, headers: [("Location", "file:///etc/passwd")]) }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: env.file("passwd").path))
    }

    // MARK: File names and destinations

    @Test func aTraversalFilenameFromTheServerStaysInsideTheDownloadFolder() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000, contentDisposition: #"attachment; filename="../../evil.txt""#)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(FileManager.default.fileExists(atPath: env.file("evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: env.root.appending(path: "evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: env.root.deletingLastPathComponent().appending(path: "evil.txt").path))
    }

    @Test func aTraversalFilenameChosenByTheCallerIsSanitizedToo() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { $0.filename = "../../../tmp/pwned.bin" })
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed)
        #expect(done.finalURL?.lastPathComponent == "pwned.bin")
        #expect(done.finalURL?.deletingLastPathComponent().resolvingSymlinksInPath().path == env.downloads.resolvingSymlinksInPath().path)
    }

    @Test func aTamperedJobFileCannotEscapeTheDownloadFolder() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        var record = DownloadRecord(url: server.url(), destinationDirectory: env.downloads, sequence: 0)
        record.filename = "../escaped.bin" // as if someone edited the persisted JSON
        try await FileJobStore(directory: env.jobs).save(record)

        let manager = env.makeManager()
        try await manager.load()
        let done = await waitForCompletion(manager, record.id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("Unsafe destination") == true, "\(done.failure ?? "")")
        #expect(!FileManager.default.fileExists(atPath: env.root.appending(path: "escaped.bin").path))
        #expect(!FileManager.default.fileExists(atPath: env.root.appending(path: "escaped.bin.part").path))
    }

    @Test func aSymlinkPlantedAtThePartFileIsNotFollowed() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let victim = env.root.appending(path: "victim.txt")
        // A dangling link: the name allocator sees nothing there, so the engine would happily open it.
        try FileManager.default.createSymbolicLink(at: env.file("file.bin.part"), withDestinationURL: victim)
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: victim.path), "data was written through the symlink")
    }

    @Test func existingFilesAreNeverOverwritten() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        try Data("keep me".utf8).write(to: env.file("file.bin"))
        let resource = MockResource(size: 30_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed)
        #expect(done.finalURL?.lastPathComponent == "file (2).bin")
        #expect(try String(contentsOf: env.file("file.bin"), encoding: .utf8) == "keep me")
        #expect(try sha256Hex(of: env.file("file (2).bin")) == sha256Hex(of: resource))
    }

    @Test func simultaneousDownloadsOfTheSameNameGetDistinctFiles() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000, bytesPerSecond: 400_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let ids = [
            try await manager.add(env.newDownload(server.url(), segments: 1)),
            try await manager.add(env.newDownload(server.url(), segments: 1)),
            try await manager.add(env.newDownload(server.url(), segments: 1)),
        ]
        var names: [String] = []
        for id in ids {
            let done = await waitForCompletion(manager, id)
            #expect(done.state == .completed, "\(done.failure ?? "")")
            names.append(done.finalURL?.lastPathComponent ?? "?")
        }
        #expect(Set(names).count == 3, "\(names)")
        for name in names { #expect(try sha256Hex(of: env.file(name)) == sha256Hex(of: resource)) }
    }

    // MARK: Quarantine

    @Test func finishedFilesAreQuarantined() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")

        let properties = try env.file("file.bin").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties?["LSQuarantineType"] as? String == "LSQuarantineTypeWebDownload")
        #expect(properties?["LSQuarantineAgentName"] as? String == "FetchThings")
    }

    @Test func quarantineCanBeDisabled() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.applyQuarantine = false }

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        #expect(await waitForCompletion(manager, id).state == .completed)
        let properties = try env.file("file.bin").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties == nil)
    }

    // MARK: Helpers

    /// Files under `root` whose bytes contain `needle`.
    private func filesContaining(_ needle: String, under root: URL) throws -> [String] {
        let bytes = Data(needle.utf8)
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.range(of: bytes) != nil { hits.append(url.lastPathComponent) }
        }
        return hits
    }
}
