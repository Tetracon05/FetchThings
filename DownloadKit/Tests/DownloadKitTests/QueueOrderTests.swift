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

    @Test func downloadsRunInTheOrderTheyWereAddedUnlessTheQueueIsChanged() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        #expect(await rig.finishOrder() == rig.ids)
    }

    // MARK: Moving

    @Test func moveToTopRunsThemFirstAndKeepsTheirOrder() async throws {
        let rig = try await Rig.make(count: 5); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.moveToTop([ids[3], ids[1]])
        #expect(await rig.queue() == [ids[1], ids[3], ids[0], ids[2], ids[4]], "they keep the order they had between them")
        #expect(await rig.finishOrder() == [ids[1], ids[3], ids[0], ids[2], ids[4]])
    }

    @Test func moveToBottomRunsThemLast() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.moveToBottom([ids[0]])
        #expect(await rig.finishOrder() == [ids[1], ids[2], ids[3], ids[0]])
    }

    @Test func aDownloadCanBePutBeforeAnotherOne() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.move([ids[3]], before: ids[1])
        #expect(await rig.queue() == [ids[0], ids[3], ids[1], ids[2]])
        await rig.manager.move([ids[0]], before: nil)
        #expect(await rig.queue() == [ids[3], ids[1], ids[2], ids[0]], "no target: the end")
        #expect(await rig.finishOrder() == [ids[3], ids[1], ids[2], ids[0]])
    }

    @Test func movingSomethingBeforeItselfOrToTheSamePlaceChangesNothing() async throws {
        let rig = try await Rig.make(count: 3); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.move([ids[1]], before: ids[1])
        #expect(await rig.queue() == ids, "in front of itself is where it is")
        await rig.manager.move([ids[1]], before: ids[2])
        await rig.manager.moveToTop([ids[0]])
        #expect(await rig.queue() == ids)
        await rig.manager.moveToTop(ids) // everything: nothing to go in front of
        await rig.manager.move([UUID()], before: ids[0]) // not a download
        #expect(await rig.queue() == ids)
    }

    @Test func aSelectionDroppedOnOneOfItsOwnRowsStaysWhereItIs() async throws {
        let rig = try await Rig.make(count: 5); defer { rig.cleanup() }
        let ids = rig.ids
        // Rows 1 and 3 are dragged and dropped in front of row 3, one of the dragged ones: they go in front of row 4.
        await rig.manager.move([ids[1], ids[3]], before: ids[3])
        #expect(await rig.queue() == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        // Dropped on the last row, one of themselves, they go to the end.
        await rig.manager.move([ids[0], ids[4]], before: ids[4])
        #expect(await rig.queue() == [ids[2], ids[1], ids[3], ids[0], ids[4]])
    }

    @Test func aFinishedDownloadHasNoPlaceInTheQueue() async throws {
        let rig = try await Rig.make(count: 3); defer { rig.cleanup() }
        let ids = rig.ids
        let order = await rig.finishOrder()
        #expect(order == ids)
        await rig.manager.moveToTop([ids[2]])
        await rig.manager.setPriority(.high, for: [ids[2]])
        let snapshot = try #require(await rig.manager.snapshot(ids[2]))
        #expect(snapshot.state == .completed && snapshot.priority == .normal, "finished downloads are left alone")
        let added = try await rig.add() // and a new one is simply last
        #expect(await rig.queue() == [added])
    }

    @Test func aTargetThatIsFinishedMeansTheEndOfTheQueue() async throws {
        let rig = try await Rig.make(count: 2); defer { rig.cleanup() }
        let finished = rig.ids[0]
        _ = await rig.finishOrder(count: 2)
        rig.network.send(.offline)
        let a = try await rig.add(), b = try await rig.add()
        await rig.manager.move([a], before: finished)
        #expect(await rig.queue() == [b, a])
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

    @Test func aDownloadTakesThePriorityOfThePlaceItIsPutIn() async throws {
        let rig = try await Rig.make(count: 4); defer { rig.cleanup() }
        let ids = rig.ids
        await rig.manager.setPriority(.high, for: [ids[0], ids[1]])
        await rig.manager.move([ids[3]], before: ids[1]) // dropped among the high-priority ones
        var byID = Dictionary(uniqueKeysWithValues: await rig.manager.allSnapshots().map { ($0.id, $0) })
        #expect(byID[ids[3]]?.priority == .high)
        #expect(await rig.queue() == [ids[0], ids[3], ids[1], ids[2]])

        await rig.manager.move([ids[0]], before: nil) // to the end: the priority of what is last
        byID = Dictionary(uniqueKeysWithValues: await rig.manager.allSnapshots().map { ($0.id, $0) })
        #expect(byID[ids[0]]?.priority == .normal)
        #expect(await rig.queue() == [ids[3], ids[1], ids[2], ids[0]])
    }

    @Test func changingPriorityDoesNotInterruptADownloadThatIsRunning() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 600_000, bytesPerSecond: 300_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager { $0.maxConcurrentDownloads = 1 }
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })
        await manager.setPriority(.low, for: [id])
        await manager.moveToBottom([id])
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
        await first.moveToTop([ids[2]])
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

    @Test func jobFilesFromBeforeTheQueueCouldBeReorderedStillLoadInTheOrderTheyWereAdded() throws {
        var record = DownloadRecord(url: URL(string: "https://example.com/a")!, destinationDirectory: URL(filePath: "/tmp"), sequence: 7)
        record.priority = .high
        record.queueRank = 1.5
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["priority"] = nil
        object["queueRank"] = nil
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.effectivePriority == .normal && old.effectiveRank == 7)
    }

    @Test func manyDownloadsPutBetweenTheSameTwoStayInOrder() async throws {
        // Ranks 0, 1 and 2. The gap between 1 and 2 halves with every download put into it, and around 1.0 a number
        // has room for about 52 halvings: 60 of them run out of numbers, and the queue is renumbered.
        let rig = try await Rig.make(count: 3); defer { rig.cleanup() }
        let ids = rig.ids
        var expected: [DownloadID] = [ids[2]]
        for _ in 0 ..< 60 {
            let added = try await rig.add()
            await rig.manager.move([added], before: expected[0])
            expected.insert(added, at: 0)
        }
        #expect(await rig.queue() == [ids[0], ids[1]] + expected, "the order holds however it was numbered")
    }

    @Test func ranksAreSpreadBetweenNeighboursAndRenumberedWhenThereIsNoRoom() {
        #expect(QueueRanks.spread(0, between: 1, and: 2) == [])
        #expect(QueueRanks.spread(3, between: nil, and: nil) == [0, 1, 2])
        #expect(QueueRanks.spread(2, between: 5, and: nil) == [6, 7])
        #expect(QueueRanks.spread(2, between: nil, and: 5) == [3, 4])
        #expect(QueueRanks.spread(2, between: 0, and: 3) == [1, 2])
        #expect(QueueRanks.spread(1, between: 1, and: 1 + 1e-12) == nil, "no room: the caller renumbers")
    }

    @Test func theOrderIsPriorityThenRankThenTheOrderAdded() {
        let a = QueueOrder(priority: .normal, rank: 2, sequence: 1)
        let b = QueueOrder(priority: .normal, rank: 1, sequence: 2)
        let c = QueueOrder(priority: .high, rank: 9, sequence: 3)
        let d = QueueOrder(priority: .low, rank: 0, sequence: 0)
        let e = QueueOrder(priority: .normal, rank: 1, sequence: 5)
        #expect([a, b, c, d, e].sorted() == [c, b, e, a, d])
    }
}
