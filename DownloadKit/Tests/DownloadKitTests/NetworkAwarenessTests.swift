import Foundation
import Synchronization
import Testing
@testable import DownloadKit

/// A network the test controls: `send` is what the system would report.
final class FakeNetwork: NetworkMonitoring {
    private struct State {
        var status: NetworkStatus
        var subscribers: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ status: NetworkStatus = .online) { state = Mutex(State(status: status)) }

    func currentStatus() async -> NetworkStatus { state.withLock { $0.status } }

    func changes() -> AsyncStream<NetworkStatus> {
        let (stream, continuation) = AsyncStream<NetworkStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        let latest = state.withLock { state -> NetworkStatus in
            state.subscribers[token] = continuation
            return state.status
        }
        continuation.yield(latest)
        return stream
    }

    func send(_ status: NetworkStatus) {
        let subscribers = state.withLock { state -> [AsyncStream<NetworkStatus>.Continuation] in
            state.status = status
            return Array(state.subscribers.values)
        }
        for continuation in subscribers { continuation.yield(status) }
    }
}

private let hotspot = NetworkStatus(isConnected: true, isExpensive: true)
private let lowData = NetworkStatus(isConnected: true, isConstrained: true)

@Suite("Network awareness")
struct NetworkAwarenessTests {
    /// A file that takes a couple of seconds over one connection, so a test can act while it is on its way.
    private func slowFile(size: Int = 600_000) -> MockResource { MockResource(size: size, bytesPerSecond: 300_000) }

    /// Waits a moment and returns how many requests reached the server, to show that nothing was asked for.
    private func quietRequests(_ server: MockHTTPServer, for time: Duration = .milliseconds(400)) async -> Int {
        try? await Task.sleep(for: time)
        return server.requests.count
    }

    // MARK: The policy

    @Test func theRulesForWhichConnectionsMayBeUsed() {
        let defaults = NetworkPolicy()
        #expect(defaults.block(for: .online) == nil)
        #expect(defaults.block(for: .offline) == .offline)
        #expect(defaults.block(for: hotspot) == nil, "a hotspot is used unless the user says otherwise")
        #expect(defaults.block(for: lowData) == .constrained, "Low Data Mode is respected unless the user says otherwise")

        let strict = NetworkPolicy(pauseOnExpensive: true, pauseOnConstrained: true)
        #expect(strict.block(for: hotspot) == .expensive)
        #expect(strict.block(for: NetworkStatus(isConnected: true, isExpensive: true, isConstrained: true)) == .expensive)

        let lax = NetworkPolicy(pauseOnExpensive: false, pauseOnConstrained: false)
        #expect(lax.block(for: lowData) == nil)
        #expect(lax.block(for: .offline) == .offline, "being offline blocks whatever is chosen")
    }

    // MARK: Offline

    @Test func goingOfflinePutsARunningDownloadBackInTheQueueAndItFinishesWhenTheConnectionReturns() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = slowFile()
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(.online)
        let manager = env.makeManager(network: network)
        try await manager.load()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })

        network.send(.offline)
        let waiting = await waitFor(manager, id, "back in the queue", until: { $0.state == .queued })
        #expect(waiting.failure == nil, "losing the connection is not a failure")
        let requests = await quietRequests(server)
        #expect(await manager.snapshot(id)?.state == .queued, "and it stays there while there is no connection")
        #expect(await quietRequests(server) == requests, "nothing is asked of the server while offline")

        network.send(.online)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
        #expect(try sha256Hex(of: env.file("file.bin")) == sha256Hex(of: resource), "and the file is whole")
    }

    @Test func startingOfflineKeepsDownloadsWaiting() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(.offline)
        let manager = env.makeManager(network: network)
        try await manager.load()

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        #expect(await quietRequests(server) == 0, "nothing is requested while there is no connection")
        #expect(await manager.snapshot(id)?.state == .queued)

        network.send(.online)
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
    }

    @Test func downloadsRestoredAtLaunchDoNotStartOffline() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }

        let first = env.makeManager()
        let id = try await first.add(env.newDownload(server.url(), segments: 1) { $0.startPaused = true })
        await first.resume(id) // queued, and left as such when the app quits
        await first.shutdown()

        let network = FakeNetwork(.offline)
        let second = env.makeManager(network: network)
        let before = server.requests.count
        try await second.load()
        #expect(await quietRequests(server) == before, "the launch reads the connection before anything is resumed")
        network.send(.online)
        let done = await waitForCompletion(second, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
    }

    @Test func aDownloadThePausedUserStaysPausedWhenTheConnectionReturns() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = slowFile()
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(.online)
        let manager = env.makeManager(network: network)
        try await manager.load()

        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })
        await manager.pause(id)
        await waitFor(manager, id, "paused", until: { $0.state == .paused })

        network.send(.offline)
        network.send(.online)
        let requests = await quietRequests(server)
        #expect(await manager.snapshot(id)?.state == .paused, "only what the connection stopped comes back by itself")
        #expect(await quietRequests(server) == requests)
    }

    // MARK: Expensive and constrained connections

    @Test func aHotspotIsUsedByDefault() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager(network: FakeNetwork(hotspot))
        try await manager.load()
        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        #expect(await waitForCompletion(manager, id).state == .completed)
    }

    @Test func aHotspotHoldsDownloadsBackWhenAskedAndTheUserCanDownloadAnyway() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 200_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(hotspot)
        let manager = env.makeManager(network: network)
        await manager.setNetworkPolicy(NetworkPolicy(pauseOnExpensive: true))
        try await manager.load()

        var states = await manager.networkStates().makeAsyncIterator()
        #expect(await states.next() == NetworkState(status: hotspot, block: .expensive, isOverridden: false))

        let id = try await manager.add(env.newDownload(server.url(), segments: 2))
        #expect(await quietRequests(server) == 0, "it waits, as the user asked")
        #expect(await manager.snapshot(id)?.state == .queued)

        await manager.overrideNetworkBlock()
        #expect(await states.next() == NetworkState(status: hotspot, block: nil, isOverridden: true))
        let done = await waitForCompletion(manager, id)
        #expect(done.state == .completed, "\(done.failure ?? "")")
    }

    @Test func theChoiceToDownloadAnywayEndsWhenTheConnectionChanges() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = slowFile()
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(hotspot)
        let manager = env.makeManager(network: network)
        await manager.setNetworkPolicy(NetworkPolicy(pauseOnExpensive: true))
        try await manager.load()
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await manager.overrideNetworkBlock()
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })

        network.send(.online)  // another network
        network.send(hotspot)  // and back on a hotspot: the earlier choice does not apply to this one
        await waitFor(manager, id, "held back again", until: { $0.state == .queued })
    }

    @Test func offlineCannotBeOverridden() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager(network: FakeNetwork(.offline))
        try await manager.load()
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await manager.overrideNetworkBlock()
        #expect(await quietRequests(server) == 0)
        #expect(await manager.snapshot(id)?.state == .queued)
    }

    @Test func lowDataModeIsRespectedByDefaultAndThePolicyCanChangeWhileDownloading() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = slowFile()
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(lowData)
        let manager = env.makeManager(network: network)
        try await manager.load()
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        #expect(await quietRequests(server) == 0, "Low Data Mode holds it back by default")

        await manager.setNetworkPolicy(NetworkPolicy(pauseOnConstrained: false))
        await waitFor(manager, id, "downloading", until: { $0.state == .downloading && $0.receivedBytes > 0 })

        await manager.setNetworkPolicy(NetworkPolicy(pauseOnConstrained: true)) // tightened while it runs
        await waitFor(manager, id, "waiting again", until: { $0.state == .queued })
    }

    @Test func aConnectionThatMerelyChangesInterfaceDoesNotInterruptDownloads() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = slowFile()
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let network = FakeNetwork(.online)
        let manager = env.makeManager(network: network)
        try await manager.load()
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        await waitFor(manager, id, "some data", until: { $0.state == .downloading && $0.receivedBytes > 0 })

        network.send(.online) // the system reports again, with nothing that matters different
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await manager.snapshot(id)?.state == .downloading)
        #expect(await waitForCompletion(manager, id).state == .completed)
    }

    // MARK: Telling the app

    @Test func theAppIsToldWhenDownloadsAreHeldBackAndWhenTheyAreFree() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let network = FakeNetwork(.online)
        let manager = env.makeManager(network: network)
        try await manager.load()

        var states = await manager.networkStates().makeAsyncIterator()
        #expect(await states.next() == .unrestricted)
        network.send(.offline)
        #expect(await states.next() == NetworkState(status: .offline, block: .offline, isOverridden: false))
        network.send(.online)
        #expect(await states.next() == .unrestricted)
    }

    @Test func theSystemMonitorAnswersPromptlyAndReportsToSubscribers() async {
        // Not what it says (that depends on the machine running the test), only that it does say something, and quickly:
        // the launch waits for this before it starts any download.
        let monitor = SystemNetworkMonitor()
        let started = ContinuousClock.now
        _ = await monitor.currentStatus()
        #expect(ContinuousClock.now - started < .seconds(3))

        var changes = monitor.changes().makeAsyncIterator()
        let first = await changes.next()
        #expect(first != nil, "a new subscriber is handed the latest status at once")
    }

    @Test func withoutAMonitorNothingIsEverHeldBack() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let resource = MockResource(size: 100_000)
        let server = try await MockHTTPServer.start { resource.response(for: $0) }; defer { server.stop() }
        let manager = env.makeManager()
        try await manager.load()
        var states = await manager.networkStates().makeAsyncIterator()
        #expect(await states.next() == .unrestricted)
        let id = try await manager.add(env.newDownload(server.url(), segments: 1))
        #expect(await waitForCompletion(manager, id).state == .completed)
    }
}
