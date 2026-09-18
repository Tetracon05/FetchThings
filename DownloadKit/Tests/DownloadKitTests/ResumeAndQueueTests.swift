import Foundation
import Synchronization
import Testing
@testable import DownloadKit

@Suite("Pause, resume and restart", .serialized)
struct ResumeTests {
    @Test func pausingKeepsProgressAndResumingDoesNotRedownload() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 2 * 1024 * 1024
        let resource = MockResource(size: size, bytesPerSecond: 1_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        await waitFor(manager, id, "30% progress") { $0.receivedBytes >= 600_000 }
        await manager.pause(id)

        let paused = try #require(await manager.snapshot(id))
        #expect(paused.state == .paused)
        #expect(paused.receivedBytes >= 600_000 && paused.receivedBytes < Int64(size))
        #expect(paused.bytesPerSecond == 0 && paused.activeConnections == 0)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await manager.snapshot(id)?.receivedBytes == paused.receivedBytes, "nothing may be written while paused")
        #expect(FileManager.default.fileExists(atPath: env.file("file.bin.part").path))

        await manager.resume(id)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(server.bodyBytesSent < size + 300_000, "resuming must not re-fetch finished bytes (sent \(server.bodyBytesSent) for \(size))")
    }

    @Test func resumeSurvivesRestartingTheApp() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 2 * 1024 * 1024
        let resource = MockResource(size: size, bytesPerSecond: 1_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 2))
        await waitFor(first, id, "30% progress") { $0.receivedBytes >= 600_000 }
        await first.pauseAll()
        let before = try #require(await first.snapshot(id))

        // The persisted record must describe real progress.
        let stored = try #require(try await FileJobStore(directory: env.jobs).loadAll().first)
        #expect(stored.state == .paused)
        #expect(stored.mode == .segmented)
        #expect(stored.downloadedBytes > 0 && stored.downloadedBytes <= before.receivedBytes)

        // A new process: new manager, same folders.
        let second = env.makeManager()
        try await second.load()
        let restored = try #require(await second.snapshot(id))
        #expect(restored.state == .paused)
        #expect(restored.receivedBytes == stored.downloadedBytes)
        #expect(restored.filename == "file.bin")

        await second.resume(id)
        let done = await waitForCompletion(second, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
        #expect(server.bodyBytesSent < size + 300_000, "resuming must not re-fetch finished bytes (sent \(server.bodyBytesSent) for \(size))")
    }

    @Test func downloadsInterruptedByAnUncleanQuitContinueOnTheirOwn() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let size = 1_500_000
        let resource = MockResource(size: size, bytesPerSecond: 750_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 2))
        await waitFor(first, id, "some progress") { $0.receivedBytes >= 400_000 }
        await first.pauseAll()

        // What a crash leaves behind: a checkpoint whose state says "downloading".
        let store = FileJobStore(directory: env.jobs)
        var record = try #require(try await store.loadAll().first)
        record.state = .downloading
        try await store.save(record)

        let second = env.makeManager()
        try await second.load()
        let done = await waitForCompletion(second, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test func aCleanShutdownRequeuesRunningDownloads() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_000_000, bytesPerSecond: 500_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 2))
        await waitFor(first, id, "some progress") { $0.receivedBytes >= 200_000 }
        await first.shutdown()

        let stored = try #require(try await FileJobStore(directory: env.jobs).loadAll().first)
        #expect(stored.state == .queued, "it should pick up again at next launch")
        #expect(stored.downloadedBytes >= 200_000)

        // ...and the manager must not have restarted it behind our back.
        let requestsAtShutdown = server.requests.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.requests.count == requestsAtShutdown, "a shut-down manager kept downloading")
        #expect(try await FileJobStore(directory: env.jobs).loadAll().first?.state == .queued)
        #expect(await first.snapshot(id)?.state == .queued)
    }

    @Test func aCompletionIsOnDiskBeforeShutdownReturns() async throws {
        // Subscribers see a state change before the store has written it. Quitting right then must not leave
        // a finished download recorded as running, or the next launch would download it all again.
        let resource = MockResource(size: 20_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        for round in 1...25 {
            let env = try TestEnvironment(); defer { env.cleanup() }
            let manager = env.makeManager()
            let stream = await manager.events()
            let id = try await manager.add(env.newDownload(server.url("/r\(round).bin"), segments: 1))
            _ = await collectEvents(stream) { event in
                if case .snapshot(let s) = event, s.id == id { return s.state == .completed }
                return false
            }
            await manager.shutdown()
            let stored = try #require(try await FileJobStore(directory: env.jobs).loadAll().first)
            #expect(stored.state == .completed, "round \(round): the completion had not been written when shutdown returned")
        }
    }

    @Test func partialDataIsDiscardedWhenTheServerFileChangedWhilePaused() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let live = LiveResource(MockResource(size: 1_500_000, seed: 1, etag: "\"v1\"", bytesPerSecond: 750_000))
        let server = try await MockHTTPServer.start { live.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        await waitFor(manager, id, "some progress") { $0.receivedBytes >= 400_000 }
        await manager.pause(id)

        live.update { $0.seed = 2; $0.etag = "\"v2\""; $0.bytesPerSecond = nil }
        await manager.resume(id)
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: live.value), "the file must be entirely the new version, never a mix")
    }

    @Test func restartsWhenTheFileChangesMidDownload() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let live = LiveResource(MockResource(size: 600_000, seed: 1, etag: "\"v1\""))
        let firstData = Counter()
        let server = try await MockHTTPServer.start { request in
            var response = live.response(for: request)
            if request.method == "GET", request.headers["range"] != "bytes=0-0", firstData.next() == 1 {
                // Serve part of v1, then the file is replaced on the server.
                response.dropAfterBodyBytes = 100_000
                live.update { $0.seed = 2; $0.etag = "\"v2\"" }
            }
            return response
        }
        defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        let done = await waitForCompletion(manager, id)

        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: live.value))
    }
}

@Suite("Queue, limits and events", .serialized)
struct QueueTests {
    @Test func neverRunsMoreDownloadsThanTheLimit() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 120_000, bytesPerSecond: 240_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 2 }

        let stream = await manager.events()
        for name in ["a", "b", "c", "d"] { try await manager.add(env.newDownload(server.url("/\(name).bin"), segments: 1)) }
        let completed = Mutex(Set<DownloadID>())
        let events = await collectEvents(stream) { event in
            guard case .snapshot(let s) = event, s.state == .completed else { return false }
            return completed.withLock { $0.insert(s.id); return $0.count == 4 }
        }

        // Replay the totally ordered event log: how many downloads were running at each step?
        var latest: [DownloadID: DownloadState] = [:]
        var peak = 0
        for case .snapshot(let snapshot) in events {
            latest[snapshot.id] = snapshot.state
            peak = max(peak, latest.values.filter(\.isRunning).count)
        }
        #expect(latest.count == 4 && latest.values.allSatisfy { $0 == .completed })
        #expect(peak == 2, "peak concurrency was \(peak)")
        for name in ["a", "b", "c", "d"] { #expect(try sha256Hex(of: env.file("\(name).bin")) == sha256Hex(of: resource)) }
    }

    @Test func queueOrderIsFirstAddedFirstStarted() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 80_000, bytesPerSecond: 160_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 1 }

        for name in ["one", "two", "three"] { try await manager.add(env.newDownload(server.url("/\(name).bin"), segments: 1)) }
        for id in await manager.allSnapshots().map(\.id) { await waitForCompletion(manager, id) }

        let order = server.requests.filter { $0.method == "HEAD" }.map(\.path)
        #expect(order == ["/one.bin", "/two.bin", "/three.bin"])
    }

    @Test func downloadsAddedPausedDoNotStartUntilResumed() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 50_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { $0.startPaused = true })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await manager.snapshot(id)?.state == .paused)
        #expect(server.requests.isEmpty)

        await manager.resume(id)
        #expect(await waitForCompletion(manager, id).state == .completed)
    }

    // Limits act by pausing the connection once bytes arrive. URLSession and the kernel buffer roughly
    // the first megabyte ahead of that, so these tests use files well beyond it: unthrottled, each of
    // them completes on loopback in a fraction of a second.

    @Test func aPerDownloadSpeedLimitIsHonored() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 6_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let clock = ContinuousClock()
        let start = clock.now
        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { $0.options.speedLimit = 2_000_000 })
        let done = await waitForCompletion(manager, id)
        let elapsed = clock.now - start

        #expect(done.state == .completed)
        #expect(done.speedLimit == 2_000_000)
        #expect(elapsed >= .milliseconds(1500), "6 MB at a 2 MB/s limit finished in \(elapsed)")
        #expect(elapsed < .seconds(10))
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource))
    }

    @Test func theGlobalSpeedLimitIsSharedAndCanBeLifted() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 3_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()
        await manager.setGlobalSpeedLimit(2_000_000)

        let clock = ContinuousClock()
        var start = clock.now
        let a = try await manager.add(env.newDownload(server.url("/a.bin"), segments: 1))
        let b = try await manager.add(env.newDownload(server.url("/b.bin"), segments: 1))
        await waitForCompletion(manager, a)
        await waitForCompletion(manager, b)
        let limited = clock.now - start
        #expect(limited >= .milliseconds(1200), "two 3 MB files sharing 2 MB/s took only \(limited)")

        await manager.setGlobalSpeedLimit(nil)
        start = clock.now
        let c = try await manager.add(env.newDownload(server.url("/c.bin"), segments: 1))
        #expect(await waitForCompletion(manager, c).state == .completed)
        #expect(clock.now - start < .milliseconds(1000), "removing the limit must take effect")
    }

    @Test func aLimitCanBeChangedWhileDownloading() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 12_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1) { $0.options.speedLimit = 1_000_000 })
        let midway = await waitFor(manager, id, "2 MB received") { $0.receivedBytes >= 2_000_000 }
        #expect(midway.state == .downloading, "at 1 MB/s the download must still be far from done")

        await manager.setSpeedLimit(nil, for: id)
        let clock = ContinuousClock()
        let start = clock.now
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed)
        #expect(clock.now - start < .seconds(3), "at 1 MB/s the remaining 10 MB would take about 10 s")
    }

    @Test func publishesOrderedStateChangesAndMonotonicProgress() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 600_000, bytesPerSecond: 600_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let stream = await manager.events()
        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        let events = await collectEvents(stream) { event in
            if case .snapshot(let s) = event { return s.state == .completed || s.state == .failed }
            return false
        }

        var states: [DownloadState] = []
        var received: [Int64] = []
        for case .snapshot(let snapshot) in events where snapshot.id == id {
            if states.last != snapshot.state { states.append(snapshot.state) }
            received.append(snapshot.receivedBytes)
        }
        #expect(states == [.queued, .probing, .downloading, .completed])
        #expect(zip(received, received.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards: \(received)")
        #expect(received.count > 4, "expected periodic progress events")
    }

    @Test func newSubscribersStartWithTheCurrentState() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let manager = env.makeManager()
        let id = try await manager.add(env.newDownload(URL(string: "http://127.0.0.1:9/never.bin")!) { $0.startPaused = true })

        let events = await collectEvents(await manager.events()) { _ in true }
        guard case .snapshot(let snapshot)? = events.first else { Issue.record("no initial event"); return }
        #expect(snapshot.id == id && snapshot.state == .paused)
    }

    @Test func reportsConnectionsAndSegmentsWhileRunning() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 2 * 1024 * 1024, bytesPerSecond: 1_000_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 4))
        let busy = await waitFor(manager, id, "four active connections") { $0.activeConnections == 4 && $0.bytesPerSecond > 0 }
        #expect(busy.segments.count >= 4)
        #expect(busy.segments.filter(\.isActive).count == 4)
        #expect(busy.eta != nil)
        await manager.remove(id)
    }

    @Test func removingCleansUpPartialFilesAndRecords() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 1_000_000, bytesPerSecond: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        await waitFor(manager, id, "some progress") { $0.receivedBytes > 50_000 }
        await manager.remove(id)

        #expect(await manager.snapshot(id) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: env.downloads.path)).isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(atPath: env.jobs.path)).isEmpty)
    }

    @Test func removingACompletedDownloadKeepsTheFileUnlessAsked() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 30_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()

        let a = try await manager.add(env.newDownload(server.url("/keep.bin"), segments: 1))
        let b = try await manager.add(env.newDownload(server.url("/drop.bin"), segments: 1))
        await waitForCompletion(manager, a); await waitForCompletion(manager, b)

        await manager.remove(a)
        await manager.remove(b, deleteFiles: true)
        #expect(FileManager.default.fileExists(atPath: env.file("keep.bin").path))
        #expect(!FileManager.default.fileExists(atPath: env.file("drop.bin").path))
    }
}
