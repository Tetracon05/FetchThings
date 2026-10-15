import DownloadKit
import Foundation
@testable import FetchThings

/// An in-memory engine: records what the model asks for and lets a test push events.
actor FakeEngine: DownloadEngine {
    private(set) var calls: [String] = []
    private(set) var added: [NewDownload] = []
    private var continuation: AsyncStream<DownloadEvent>.Continuation?
    var addError: (any Error)?
    var failingHosts: Set<String> = []
    /// What the model told the engine about the network (kept apart from `calls`, whose exact order tests check).
    private(set) var networkPolicies: [NetworkPolicy] = []
    private(set) var networkOverrides = 0
    /// What the model asked about priority, in words (`priority 1 2`), kept apart from `calls` like the network ones.
    private(set) var queueCalls: [String] = []
    private var networkContinuation: AsyncStream<NetworkState>.Continuation?
    /// Whether `load` came after the policy was set: the launch must know the policy before it starts anything.
    private(set) var policySetBeforeLoad = false

    func load() async throws {
        policySetBeforeLoad = !networkPolicies.isEmpty
        calls.append("load")
    }
    func shutdown() async { calls.append("shutdown"); continuation?.finish() }

    func events() async -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func add(_ request: NewDownload) async throws -> DownloadID {
        if failingHosts.contains(request.url.host() ?? "") { throw DownloadError.unsupportedURL("refused by fake") }
        if let addError { throw addError }
        added.append(request)
        return UUID()
    }

    func pause(_ id: DownloadID) async { calls.append("pause \(id)") }
    func resume(_ id: DownloadID) async { calls.append("resume \(id)") }
    func pauseAll() async { calls.append("pauseAll") }
    func resumeAll() async { calls.append("resumeAll") }
    func remove(_ id: DownloadID, deleteFiles: Bool) async { calls.append("remove \(id) deleteFiles=\(deleteFiles)") }
    func setMaxConcurrentDownloads(_ count: Int) async { calls.append("maxConcurrent \(count)") }
    func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) async { calls.append("globalLimit \(bytesPerSecond.map(String.init) ?? "nil")") }

    func setPriority(_ priority: DownloadPriority, for ids: [DownloadID]) async { queueCalls.append("priority \(priority.rawValue) \(ids.count)") }
    func setNetworkPolicy(_ policy: NetworkPolicy) async { networkPolicies.append(policy) }
    func overrideNetworkBlock() async { networkOverrides += 1 }

    func networkStates() async -> AsyncStream<NetworkState> {
        let (stream, continuation) = AsyncStream<NetworkState>.makeStream()
        networkContinuation = continuation
        continuation.yield(.unrestricted)
        return stream
    }

    func sendNetwork(_ state: NetworkState) { networkContinuation?.yield(state) }

    func send(_ event: DownloadEvent) { continuation?.yield(event) }
    func failAdds(forHost host: String) { failingHosts.insert(host) }
}

@MainActor
final class FakePasteboard: PasteboardSource {
    var changeCount = 0
    var linksOnClipboard: [URL] = []
    private(set) var copied: [String] = []

    func links() async -> [URL] { linksOnClipboard }

    func copy(_ text: String) -> Int {
        copied.append(text)
        changeCount += 1
        return changeCount
    }

    /// Simulates another app copying something.
    func externalCopy(_ links: [URL]) {
        linksOnClipboard = links
        changeCount += 1
    }
}

func snapshot(
    _ name: String? = nil,
    url: String = "https://example.com/file.bin",
    state: DownloadState = .queued,
    total: Int64? = 1000,
    received: Int64 = 0,
    speed: Double = 0,
    created: TimeInterval = 0,
    failure: String? = nil,
    finalURL: URL? = nil,
    sequence: Int = 0,
    priority: DownloadPriority = .normal,
    completedAt: TimeInterval? = nil
) -> DownloadSnapshot {
    DownloadSnapshot(
        url: URL(string: url)!,
        filename: name,
        destinationDirectory: URL(filePath: "/tmp/dl"),
        state: state,
        totalBytes: total,
        receivedBytes: received,
        bytesPerSecond: speed,
        failure: failure,
        createdAt: Date(timeIntervalSince1970: created),
        completedAt: completedAt.map { Date(timeIntervalSince1970: $0) },
        finalURL: finalURL,
        sequence: sequence,
        priority: priority
    )
}

@MainActor
func makeModel(
    engine: FakeEngine = FakeEngine(),
    pasteboard: FakePasteboard = FakePasteboard(),
    configure: (AppSettings) -> Void = { _ in }
) -> (model: AppModel, engine: FakeEngine, pasteboard: FakePasteboard, settings: AppSettings) {
    let suite = "FetchThingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: defaults)
    configure(settings)
    return (AppModel(engine: engine, settings: settings, pasteboard: pasteboard), engine, pasteboard, settings)
}

/// Feeds snapshots through the model's own path and applies them.
@MainActor
func deliver(_ snapshots: [DownloadSnapshot], to model: AppModel, engine: FakeEngine) async {
    for snapshot in snapshots { await engine.send(.snapshot(snapshot)) }
    try? await Task.sleep(for: .milliseconds(50))
}

/// Waits (briefly) until `condition` holds.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
