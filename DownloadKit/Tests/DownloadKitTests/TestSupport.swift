import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import DownloadKit

/// A throwaway download folder and job store, plus helpers to drive a `DownloadManager`.
struct TestEnvironment: Sendable {
    let root: URL
    let downloads: URL
    let jobs: URL
    let secrets = InMemorySecretStore()

    init() throws {
        root = URL(filePath: NSTemporaryDirectory()).appending(path: "DownloadKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        jobs = root.appending(path: "Jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func fastConfiguration() -> EngineConfiguration {
        var configuration = EngineConfiguration()
        configuration.minSegmentSize = 16 * 1024
        configuration.retryPolicy.baseDelay = 0.01
        configuration.retryPolicy.maxDelay = 0.05
        configuration.progressInterval = .milliseconds(40)
        configuration.checkpointInterval = .milliseconds(100)
        return configuration
    }

    func makeManager(_ customize: (inout EngineConfiguration) -> Void = { _ in }) -> DownloadManager {
        var configuration = Self.fastConfiguration()
        customize(&configuration)
        return DownloadManager(configuration: configuration, store: FileJobStore(directory: jobs), secrets: secrets)
    }

    func newDownload(_ url: URL, segments: Int? = nil, customize: (inout NewDownload) -> Void = { _ in }) -> NewDownload {
        var request = NewDownload(url: url, destinationDirectory: downloads, options: DownloadOptions(segmentCount: segments))
        customize(&request)
        return request
    }

    func file(_ name: String) -> URL { downloads.appending(path: name, directoryHint: .notDirectory) }
}

/// Polls until `condition` holds for the download, failing the test after `timeout`.
@discardableResult
func waitFor(
    _ manager: DownloadManager,
    _ id: DownloadID,
    timeout: Duration = .seconds(30),
    _ description: String = "condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    until condition: (DownloadSnapshot) -> Bool
) async -> DownloadSnapshot {
    let deadline = ContinuousClock.now + timeout
    var last: DownloadSnapshot?
    while ContinuousClock.now < deadline {
        if let snapshot = await manager.snapshot(id) {
            last = snapshot
            if condition(snapshot) { return snapshot }
        }
        try? await Task.sleep(for: .milliseconds(15))
    }
    Issue.record("Timed out waiting for \(description); last state: \(String(describing: last?.state)), failure: \(last?.failure ?? "-")", sourceLocation: sourceLocation)
    return last ?? DownloadSnapshot(
        id: id, url: URL(string: "about:blank")!, filename: nil, destinationDirectory: URL(filePath: "/"), state: .failed, mode: nil,
        totalBytes: nil, receivedBytes: 0, bytesPerSecond: 0, eta: nil, activeConnections: 0, segments: [], failure: "timeout",
        createdAt: Date(), completedAt: nil, speedLimit: nil, checksumVerified: nil, finalURL: nil
    )
}

@discardableResult
func waitForCompletion(_ manager: DownloadManager, _ id: DownloadID, sourceLocation: SourceLocation = #_sourceLocation) async -> DownloadSnapshot {
    await waitFor(manager, id, "completion", sourceLocation: sourceLocation) { $0.state == .completed || $0.state == .failed }
}

func sha256Hex(of file: URL) throws -> String {
    var hasher = SHA256()
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().hexString
}

func sha256Hex(of resource: MockResource) -> String {
    sha256Hex(of: MockContent.data(seed: resource.seed, length: resource.size))
}

func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).hexString
}

/// A resource whose content can change while a test runs.
final class LiveResource: Sendable {
    private let storage: Mutex<MockResource>
    init(_ resource: MockResource) { storage = Mutex(resource) }
    var value: MockResource { storage.withLock { $0 } }
    func update(_ change: (inout MockResource) -> Void) { storage.withLock { change(&$0) } }
    func response(for request: MockRequest) -> MockResponse { value.response(for: request) }
}

extension MockHTTPServer {
    /// Everything except the prober's HEAD and its `Range: bytes=0-0` GET.
    var dataRequests: [MockRequest] {
        requests.filter { $0.method == "GET" && $0.headers["range"] != "bytes=0-0" }
    }
}

/// Collects events until `stop` returns true, or gives up after `timeout`.
func collectEvents(
    _ stream: AsyncStream<DownloadEvent>,
    timeout: Duration = .seconds(30),
    until stop: @escaping @Sendable (DownloadEvent) -> Bool
) async -> [DownloadEvent] {
    let collector = Task { () -> [DownloadEvent] in
        var events: [DownloadEvent] = []
        for await event in stream {
            events.append(event)
            if stop(event) { break }
        }
        return events
    }
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        collector.cancel()
    }
    defer { watchdog.cancel() }
    return await collector.value
}
