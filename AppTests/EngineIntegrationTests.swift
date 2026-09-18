import CryptoKit
import DownloadKit
import Foundation
import Testing
@testable import Downloader

/// The model wired to the real engine (no fake), downloading from a local server.
@MainActor
@Suite("Model with the real engine", .serialized)
struct EngineIntegrationTests {
    private struct Rig {
        let model: AppModel
        let manager: DownloadManager
        let folder: URL
        let root: URL
    }

    private func makeRig() throws -> Rig {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "app-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = EngineConfiguration()
        configuration.progressInterval = .milliseconds(50)
        configuration.checkpointInterval = .milliseconds(150)
        let manager = DownloadManager(configuration: configuration, store: FileJobStore(directory: root.appending(path: "Jobs")), secrets: InMemorySecretStore())
        let suite = "DownloaderTests.rig.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.downloadFolder = folder
        return Rig(model: AppModel(engine: manager, settings: settings, pasteboard: FakePasteboard()), manager: manager, folder: folder, root: root)
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func aDownloadFlowsFromTheEngineIntoTheTableState() async throws {
        let rig = try makeRig(); defer { try? FileManager.default.removeItem(at: rig.root) }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = try await TinyHTTPServer.start(body: payload); defer { server.stop() }
        var completions: [String] = []
        rig.model.onCompleted = { completions.append($0.displayName) }
        rig.model.start()

        let request = NewDownload(url: server.url("/payload.bin"), destinationDirectory: rig.folder)
        let outcome = await rig.model.add([request])
        #expect(outcome.added == 1 && outcome.failures.isEmpty)

        #expect(await eventually(timeout: .seconds(20)) { rig.model.flushEvents(); return rig.model.visibleDownloads.first?.state == .completed })
        let done = try #require(rig.model.visibleDownloads.first)
        #expect(done.displayName == "payload.bin")
        #expect(done.totalBytes == Int64(payload.count) && done.receivedBytes == Int64(payload.count) && done.fraction == 1)
        #expect(try sha(Data(contentsOf: rig.folder.appending(path: "payload.bin"))) == sha(payload))
        #expect(rig.model.count(for: .completed) == 1 && rig.model.count(for: .active) == 0)
        #expect(rig.model.count(for: .category(.other)) == 1)
        #expect(completions == ["payload.bin"], "completion is announced exactly once")
        await rig.model.shutdown()
    }

    @Test func pauseResumeAndRemoveThroughTheModel() async throws {
        let rig = try makeRig(); defer { try? FileManager.default.removeItem(at: rig.root) }
        let payload = Data(repeating: 0x5A, count: 600_000)
        // ~40 chunks at 25 ms each: about a second in flight.
        let server = try await TinyHTTPServer.start(body: payload, chunkSize: 16 * 1024, delay: .milliseconds(25)); defer { server.stop() }
        rig.model.start()
        _ = await rig.model.add([NewDownload(url: server.url("/slow.bin"), destinationDirectory: rig.folder)])

        #expect(await eventually(timeout: .seconds(10)) { rig.model.flushEvents(); return rig.model.visibleDownloads.first?.state == .downloading })
        let id = try #require(rig.model.visibleDownloads.first?.id)
        rig.model.selection = [id]
        #expect(rig.model.canPauseSelection)

        rig.model.pauseSelection()
        #expect(await eventually(timeout: .seconds(10)) { rig.model.flushEvents(); return rig.model.downloads[id]?.state == .paused })
        #expect(rig.model.canResumeSelection && !rig.model.canPauseSelection)
        #expect(rig.model.count(for: .active) == 1, "a paused download is still active work")

        rig.model.resumeSelection()
        #expect(await eventually(timeout: .seconds(20)) { rig.model.flushEvents(); return rig.model.downloads[id]?.state == .completed })
        #expect(try Data(contentsOf: rig.folder.appending(path: "slow.bin")) == payload)

        var trashed: [URL] = []
        rig.model.trash = { trashed.append($0); try FileManager.default.removeItem(at: $0) } // stands in for the Trash
        rig.model.selection = [id]
        rig.model.requestRemoval(rig.model.selection, trashFiles: true)
        #expect(await eventually { rig.model.flushEvents(); return rig.model.downloads.isEmpty })
        #expect(rig.model.selection.isEmpty)
        #expect(trashed.map(\.lastPathComponent) == ["slow.bin"])
        #expect(!FileManager.default.fileExists(atPath: rig.folder.appending(path: "slow.bin").path), "the file left the download folder")
        await rig.model.shutdown()
    }

    @Test func aFailingDownloadShowsUpAsFailedWithItsReason() async throws {
        let rig = try makeRig(); defer { try? FileManager.default.removeItem(at: rig.root) }
        let server = try await TinyHTTPServer.start(body: Data()); defer { server.stop() }
        let url = server.url("/gone.bin")
        server.stop() // nothing is listening any more
        try await Task.sleep(for: .milliseconds(100))
        rig.model.start()
        _ = await rig.model.add([NewDownload(url: url, destinationDirectory: rig.folder)])

        #expect(await eventually(timeout: .seconds(30)) { rig.model.flushEvents(); return rig.model.downloads.values.first?.state == .failed })
        let failed = try #require(rig.model.downloads.values.first)
        #expect(failed.failure?.isEmpty == false)
        #expect(rig.model.count(for: .failed) == 1 && SidebarItem.failed.includes(failed))
        #expect(failed.isResumable, "a failed download offers Retry")
        await rig.model.shutdown()
    }

    @Test func downloadsSurviveTheModelBeingRecreated() async throws {
        let rig = try makeRig(); defer { try? FileManager.default.removeItem(at: rig.root) }
        let payload = Data(repeating: 1, count: 100_000)
        let server = try await TinyHTTPServer.start(body: payload); defer { server.stop() }
        rig.model.start()
        _ = await rig.model.add([NewDownload(url: server.url("/keep.bin"), destinationDirectory: rig.folder)])
        #expect(await eventually(timeout: .seconds(20)) { rig.model.flushEvents(); return rig.model.downloads.values.first?.state == .completed })
        await rig.model.shutdown()

        // A new manager over the same job folder, as after relaunching the app.
        let manager = DownloadManager(store: FileJobStore(directory: rig.root.appending(path: "Jobs")), secrets: InMemorySecretStore())
        let relaunched = AppModel(engine: manager, settings: rig.model.settings, pasteboard: FakePasteboard())
        relaunched.start()
        #expect(await eventually { relaunched.flushEvents(); return relaunched.visibleDownloads.count == 1 })
        #expect(relaunched.visibleDownloads.first?.state == .completed && relaunched.visibleDownloads.first?.displayName == "keep.bin")
        await relaunched.shutdown()
    }
}
