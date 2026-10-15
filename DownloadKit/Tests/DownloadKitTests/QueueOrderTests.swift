import Foundation
import Testing
@testable import DownloadKit

@Suite("Queue order")
struct QueueOrderTests {
    /// A queue of downloads that cannot start yet (the network is "offline") and can only run one at a time, so the order
    /// they run in is the order of the queue, and can be read from the order they finish in.
    private struct Rig {
        let env: TestEnvironment
        let server: MockHTTPServer
        let network: FakeNetwork
        let manager: DownloadManager
        var ids: [DownloadID] = []

        static func make(count: Int) async throws -> Rig {
            let env = try TestEnvironment()
            let resource = MockResource(size: 40_000)
            let server = try await MockHTTPServer.start { resource.response(for: $0) }
            let network = FakeNetwork(.offline)
            let manager = env.makeManager(network: network) { $0.maxConcurrentDownloads = 1 }
            try await manager.load()
            var rig = Rig(env: env, server: server, network: network, manager: manager)
            for _ in 0 ..< count { rig.ids.append(try await rig.add()) }
            return rig
        }

        private init(env: TestEnvironment, server: MockHTTPServer, network: FakeNetwork, manager: DownloadManager) {
            self.env = env
            self.server = server
            self.network = network
            self.manager = manager
        }

        func add() async throws -> DownloadID {
            try await manager.add(env.newDownload(server.url(), segments: 1))
        }

        func cleanup() {
            server.stop()
            env.cleanup()
        }

        /// The downloads in the order they finish once the network is there.
        func finishOrder(count: Int? = nil) async -> [DownloadID] {
            let waiting = await manager.allSnapshots().filter { $0.state != .completed }.count
            let total = count ?? waiting
            let events = await manager.events()
            network.send(.online)
            return await withTaskGroup(of: [DownloadID].self) { group in
                group.addTask {
                    var done: [DownloadID] = []
                    for await event in events {
                        if case .snapshot(let snapshot) = event, snapshot.state == .completed, !done.contains(snapshot.id) {
                            done.append(snapshot.id)
                            if done.count == total { break }
                        }
                    }
                    return done
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(20))
                    return []
                }
                let first = await group.next() ?? []
                group.cancelAll()
                return first
            }
        }

        /// The queue as the manager reports it: not finished, in the order they will run.
        func queue() async -> [DownloadID] {
            await manager.allSnapshots().filter { $0.state != .completed }.sorted { $0.queueOrder < $1.queueOrder }.map(\.id)
        }
    }

    @Test func downloadsRunInTheOrderTheyWereAdded() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        #expect(await rig.finishOrder() == rig.ids)
    }

    // MARK: Priority

    @Test func aHigherPriorityRunsFirstWhereverItWasAdded() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.setPriority(.high, for: [ids[3]])
        await rig.manager.setPriority(.low, for: [ids[0]])
        #expect(await rig.finishOrder() == [ids[3], ids[1], ids[2], ids[0]])
    }

    @Test func aNewDownloadGoesAfterHighPriorityOnesAndBeforeLowPriorityOnes() async throws {
        let rig = try await Rig.make(count: 3); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.setPriority(.high, for: [ids[2]])
        await rig.manager.setPriority(.low, for: [ids[0]])
        let added = try await rig.add()
        #expect(await rig.queue() == [ids[2], ids[1], added, ids[0]])
    }

    @Test func aFinishedDownloadsPriorityCannotBeChanged() async throws {
        let rig = try await Rig.make(count: 3); defer { rig.cleanup() }
        let ids = rig.ids
        let order = await rig.finishOrder()
        #expect(order == ids)
        await rig.manager.setPriority(.high, for: [ids[2]])
        let snapshot = try #require(await rig.manager.snapshot(ids[2]))
        #expect(snapshot.state == .completed && snapshot.priority == .normal, "finished downloads are left alone")
        let added = try await rig.add() // and a new one is simply last
        #expect(await rig.queue() == [added])
    }

    @Test func changingPriorityDoesNotInterruptADownloadThatIsRunning() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 600_000, bytesPerSecond: 300_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 1 }
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })
        await manager.setPriority(.low, for: [id])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await manager.snapshot(id)?.state == .downloading)
        #expect(await waitForCompletion(manager, id).state == .completed)
    }

    // MARK: Keeping the order

    @Test func theOrderAndPrioritySurviveARestart() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 40_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let first = env.makeManager(network: FakeNetwork(.offline)) { $0.maxConcurrentDownloads = 1 }
        try await first.load()
        var ids: [DownloadID] = []
        for _ in 0 ..< 4 { ids.append(try await first.add(env.newDownload(server.url(), segments: 1))) }
        await first.setPriority(.high, for: [ids[2]])
        await first.setPriority(.low, for: [ids[3]])
        let before = await first.allSnapshots().sorted { $0.queueOrder < $1.queueOrder }.map(\.id)
        await first.shutdown()

        let second = env.makeManager(network: FakeNetwork(.offline)) { $0.maxConcurrentDownloads = 1 }
        try await second.load()
        let after = await second.allSnapshots().sorted { $0.queueOrder < $1.queueOrder }.map(\.id)
        #expect(after == before, "the queue is what it was when the app quit")
        #expect(after == [ids[2], ids[0], ids[1], ids[3]])
        #expect(await second.snapshot(ids[3])?.priority == .low)
    }

    @Test func jobFilesFromBeforeThePriorityFieldExistedLoadAtNormalPriority() throws {
        var record = DownloadRecord(url: URL(string: "https://example.com/a")!, destinationDirectory: URL(filePath: "/tmp"), sequence: 7)
        record.priority = .high
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["priority"] = nil
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.effectivePriority == .normal)
    }

    @Test func theOrderIsPriorityThenTheOrderAdded() {
        let a = QueueOrder(priority: .normal, sequence: 1)
        let b = QueueOrder(priority: .normal, sequence: 2)
        let c = QueueOrder(priority: .high, sequence: 3)
        let d = QueueOrder(priority: .low, sequence: 0)
        #expect([a, b, c, d].sorted() == [c, a, b, d])
    }
}
