import Foundation
import Synchronization
import Testing
@testable import DownloadKit

/// One test per defect found in the Phase 1 code review, plus the coverage gaps it named.
@Suite("Review regressions", .serialized)
struct ReviewRegressionTests {
    // MARK: Resume must not trust damaged state

    @Test func aTruncatedPartFileForcesARestartInsteadOfACorruptResult() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 2 * 1024 * 1024
        let resource = MockResource(size: size, bytesPerSecond: 1_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        await waitFor(manager, id, "progress") { $0.receivedBytes >= 600_000 }
        await manager.pause(id)
        // The checkpoint says 600 KB+ are safe, but the file was cut short while the app was paused.
        let handle = try FileHandle(forWritingTo: env.file("file.bin.part"))
        try handle.truncate(atOffset: 100_000)
        try handle.close()

        await manager.resume(id)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource), "zero-filled holes were accepted as data")
    }

    @Test func aMissingPartFileForcesARestart() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_500_000, bytesPerSecond: 750_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        await waitFor(manager, id, "progress") { $0.receivedBytes >= 400_000 }
        await manager.pause(id)
        try FileManager.default.removeItem(at: env.file("file.bin.part"))

        await manager.resume(id)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test func aCorruptJobFileIsDiscardedNotTrapped() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_200_000, bytesPerSecond: 600_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 2))
        await waitFor(first, id, "progress") { $0.receivedBytes >= 300_000 }
        await first.pauseAll()

        // Damage what is on disk: an index that does not match its position used to trap the whole process.
        let store = FileJobStore(directory: env.jobs)
        var record = try #require(try await store.loadAll().first)
        record.segments[0].index = 5
        try await store.save(record)

        let second = env.makeManager()
        try await second.load()
        await second.resume(id)
        let done = await waitForCompletion(second, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test(arguments: [
        ("valid", [Segment(index: 0, start: 0, end: 49, received: 10), Segment(index: 1, start: 50, end: 99)], true),
        ("out of creation order but tiling", [Segment(index: 0, start: 50, end: 99), Segment(index: 1, start: 0, end: 49)], true),
        ("wrong index", [Segment(index: 5, start: 0, end: 99)], false),
        ("gap", [Segment(index: 0, start: 0, end: 39), Segment(index: 1, start: 50, end: 99)], false),
        ("overlap", [Segment(index: 0, start: 0, end: 59), Segment(index: 1, start: 50, end: 99)], false),
        ("short of the total", [Segment(index: 0, start: 0, end: 49)], false),
        ("past the total", [Segment(index: 0, start: 0, end: 100)], false),
        ("negative start", [Segment(index: 0, start: -5, end: 94)], false),
        ("inverted", [Segment(index: 0, start: 99, end: 0)], false),
        ("more received than length", [Segment(index: 0, start: 0, end: 99, received: 101)], false),
        ("negative received", [Segment(index: 0, start: 0, end: 99, received: -1)], false),
        ("empty", [], false),
    ] as [(String, [Segment], Bool)])
    func validatesSavedSegmentPlans(name: String, segments: [Segment], expected: Bool) {
        #expect(SegmentPlanner.isValidPlan(segments, totalSize: 100) == expected, "\(name)")
    }

    @Test func aPartFileThatCannotBeAllocatedThrowsCleanly() throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        #expect(throws: DownloadError.self) { try PartFile(url: env.file("huge.part"), size: Int64.max) }
        // The descriptor must not have been closed twice: a fresh file still opens and writes fine.
        let file = try PartFile(url: env.file("ok.part"), size: 10)
        try file.write(Data("abc".utf8), at: 0)
        #expect(file.size == 10)
    }

    // MARK: Non-resumable downloads

    @Test func anInterruptedSingleConnectionDownloadShowsNoProgressAndRestartsFromZero() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 3 * 1024 * 1024, honorsRange: false, advertisesRanges: false, bytesPerSecond: 1_500_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        await waitFor(manager, id, "progress") { $0.receivedBytes >= 500_000 }
        await manager.pause(id)

        let paused = try #require(await manager.snapshot(id))
        #expect(!paused.supportsResume)
        #expect(paused.receivedBytes == 0, "nothing survives a stop here, so progress must not pretend otherwise")

        await manager.resume(id)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    // MARK: Probing

    @Test func aServerThatRejectsRangeRequestsStillDownloadsOverOneConnection() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 300_000, advertisesRanges: false)
        let server = try await MockHTTPServer.start { request in
            request.headers["range"] != nil ? .status(403) : resource.response(for: request)
        }
        defer { server.stop() }

        let context = RequestContext(url: server.url(), options: .init(), sensitive: .init(), defaultUserAgent: nil, timeout: 10)
        let probe = try await Prober(context: context).probe()
        #expect(!probe.acceptsRanges)
        #expect(probe.contentLength == 300_000)

        let manager = env.makeManager()
        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.mode == .single)
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    // MARK: Scheduling races

    @Test func pausingRightAfterAddingAlwaysSticks() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 400_000, bytesPerSecond: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        // Pause lands while the manager still shows the job as queued although it is already starting.
        for round in 1...25 {
            let id = try await manager.add(env.newDownload(server.url("/r\(round).bin"), segments: 1))
            await manager.pause(id)
            try await Task.sleep(for: .milliseconds(15))
            #expect(await manager.snapshot(id)?.state == .paused, "round \(round): pause was ignored")
            await manager.remove(id)
        }
    }

    @Test func aPausedQueuedDownloadDoesNotHoldASlot() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 150_000, bytesPerSecond: 300_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 1 }

        let a = try await manager.add(env.newDownload(server.url("/a.bin"), segments: 1))
        let b = try await manager.add(env.newDownload(server.url("/b.bin"), segments: 1))
        await manager.pause(b)
        await waitForCompletion(manager, a)
        let c = try await manager.add(env.newDownload(server.url("/c.bin"), segments: 1))

        #expect(await waitForCompletion(manager, c).state == .completed, "the paused download must not keep the only slot")
        #expect(await manager.snapshot(b)?.state == .paused)
    }

    @Test func pauseAllStopsRunningAndQueuedAndResumeAllRestartsThem() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 600_000, bytesPerSecond: 300_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 2 }

        var ids: [DownloadID] = []
        for name in ["a", "b", "c"] { ids.append(try await manager.add(env.newDownload(server.url("/\(name).bin"), segments: 1))) }
        await waitFor(manager, ids[0], "downloading") { $0.state == .downloading }
        await manager.pauseAll()

        for id in ids { #expect(await manager.snapshot(id)?.state == .paused) }
        let requests = server.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == requests, "nothing may start while everything is paused")

        await manager.resumeAll()
        for (id, name) in zip(ids, ["a", "b", "c"]) {
            let done = await waitForCompletion(manager, id)
            #expect(done.state == .completed, "\(done.failure ?? "")")
            #expect(try sha256Hex(of: env.file("\(name).bin")) == sha256Hex(of: resource))
        }
    }

    @Test func downloadsCanBeLeftPausedOnLaunch() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_000_000, bytesPerSecond: 500_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 2))
        await waitFor(first, id, "progress") { $0.receivedBytes >= 200_000 }
        await first.pauseAll()
        let store = FileJobStore(directory: env.jobs)
        var record = try #require(try await store.loadAll().first)
        record.state = .downloading // as an unclean quit leaves it
        try await store.save(record)

        let second = env.makeManager { $0.autoResumeOnLoad = false }
        try await second.load()
        #expect(await second.snapshot(id)?.state == .paused)
        let requests = server.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == requests)

        await second.resume(id)
        #expect(await waitForCompletion(second, id).state == .completed)
    }

    // MARK: File names

    @Test func aNameReservedForADownloadIsReleasedEvenIfTheFinishedFileGotAnotherName() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 60_000)
        let firstData = Counter()
        let blocker = env.file("file.bin")
        let server = try await MockHTTPServer.start { request in
            // Someone drops a file with the reserved name while the download is in flight.
            if request.method == "GET", request.headers["range"] != "bytes=0-0", firstData.next() == 1 {
                try? Data("blocker".utf8).write(to: blocker)
            }
            return resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let first = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, first)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(done.finalURL?.lastPathComponent == "file (2).bin", "the rename must not overwrite the blocker")

        try FileManager.default.removeItem(at: blocker)
        let second = try await manager.add(env.newDownload(server.url(), segments: 1))
        #expect(await waitForCompletion(manager, second).finalURL?.lastPathComponent == "file.bin", "the original reservation leaked")
    }

    // MARK: Server behavior

    @Test func continuesAfterAServerAnswersWithLessThanItWasAsked() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 400_000)
        let server = try await MockHTTPServer.start { request in
            var response = resource.response(for: request)
            if request.method == "GET", request.headers["range"] != "bytes=0-0", response.status == 206, let range = request.range {
                // A legal 206 that covers only the first 60 KB of what was requested.
                let served = min(response.body.length, 60_000)
                response.headers.removeAll { $0.0 == "Content-Range" }
                response.headers.append(("Content-Range", "bytes \(range.start)-\(range.start + served - 1)/\(resource.size)"))
                response.body = .generated(seed: resource.seed, offset: range.start, length: served)
            }
            return response
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(server.dataRequests.count >= 7, "400 KB in 60 KB pieces needs at least 7 requests, saw \(server.dataRequests.count)")
    }

    @Test func honorsRetryAfterBeforeRetrying() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let failures = Counter()
        let server = try await MockHTTPServer.start { request in
            if request.method == "GET", request.headers["range"] != "bytes=0-0", failures.next() == 1 {
                return .status(503, headers: [("Retry-After", "1")])
            }
            return resource.response(for: request)
        }
        defer { server.stop() }
        let manager = env.makeManager() // backoff itself is only 10-50 ms in tests

        let clock = ContinuousClock()
        let start = clock.now
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(clock.now - start >= .milliseconds(900), "the retry came after \(clock.now - start), ignoring Retry-After: 1")
    }

    // MARK: Link import

    @Test func aHugeSingleLineDoesNotStallImport() {
        let line = (0..<250_000).map { "https://example.com/file\($0)" }.joined(separator: " ") // one line, ~9 MB
        let clock = ContinuousClock()
        let start = clock.now
        let urls = LinkParser.urls(in: line)
        #expect(clock.now - start < .seconds(5), "took \(clock.now - start)")
        #expect(urls.count == LinkParser.maxLinks)
        #expect(urls.first?.absoluteString == "https://example.com/file0")
    }

    @Test func longLinesStillYieldTheirLinksWithSurroundingPunctuation() {
        let filler = String(repeating: "lorem ipsum ", count: 500) // pushes the line over the detector limit
        let urls = LinkParser.urls(in: filler + "(https://example.com/a.zip), <https://example.com/b.zip> \"https://example.com/c.zip\".")
        #expect(urls.map(\.absoluteString) == ["https://example.com/a.zip", "https://example.com/b.zip", "https://example.com/c.zip"])
    }

    // MARK: Secrets

    @Test func aDownloadThatNeededSecretsFailsWhenTheyCannotBeRead() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let server = try await MockHTTPServer.start { MockResource(size: 50_000).response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 1) {
            $0.sensitive.cookies = "session=abc"
            $0.startPaused = true
        })
        await first.shutdown()

        // The next launch cannot read the secret (keychain locked, entry removed, or an in-memory store).
        let second = DownloadManager(configuration: TestEnvironment.fastConfiguration(), store: FileJobStore(directory: env.jobs), secrets: InMemorySecretStore())
        try await second.load()
        await second.resume(id)
        let done = await waitForCompletion(second, id)

        #expect(done.state == .failed)
        #expect(done.failure?.contains("cookies or credentials") == true, "\(done.failure ?? "")")
        #expect(server.requests.isEmpty, "it must not have tried unauthenticated")
        #expect(!DownloadError.credentialsUnavailable.isRetryable)
    }

    @Test func downloadsWithoutSecretsAreUnaffectedByAnEmptySecretStore() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 30_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 1) { $0.startPaused = true })
        await first.shutdown()
        let second = DownloadManager(configuration: TestEnvironment.fastConfiguration(), store: FileJobStore(directory: env.jobs), secrets: InMemorySecretStore())
        try await second.load()
        await second.resume(id)
        #expect(await waitForCompletion(second, id).state == .completed)
    }

    @Test func theSecretFlagIsStoredButNotTheSecrets() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let manager = env.makeManager()
        _ = try await manager.add(env.newDownload(URL(string: "https://example.com/x")!, segments: 1) {
            $0.sensitive.cookies = "session=VERYSECRET"
            $0.startPaused = true
        })
        let record = try #require(try await FileJobStore(directory: env.jobs).loadAll().first)
        #expect(record.hasSecrets == true)
        let json = try String(contentsOf: env.jobs.appending(path: "\(record.id.uuidString).json"), encoding: .utf8)
        #expect(!json.contains("VERYSECRET"))
    }
}

