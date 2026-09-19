import DownloadKit
import Foundation
@testable import Downloader

/// An in-memory engine: records what the model asks for and lets a test push events.
actor FakeEngine: DownloadEngine {
    private(set) var calls: [String] = []
    private(set) var added: [NewDownload] = []
    private var continuation: AsyncStream<DownloadEvent>.Continuation?
    var addError: (any Error)?
    var failingHosts: Set<String> = []

    func load() async throws { calls.append("load") }
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
    finalURL: URL? = nil
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
        finalURL: finalURL
    )
}

@MainActor
func makeModel(
    engine: FakeEngine = FakeEngine(),
    pasteboard: FakePasteboard = FakePasteboard(),
    configure: (AppSettings) -> Void = { _ in }
) -> (model: AppModel, engine: FakeEngine, pasteboard: FakePasteboard, settings: AppSettings) {
    let suite = "DownloaderTests.\(UUID().uuidString)"
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
