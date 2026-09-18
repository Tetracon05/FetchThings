import DownloadKit

/// What the app needs from the download engine. `DownloadManager` is the real implementation; tests
/// substitute a fake so the model can be exercised without any network.
protocol DownloadEngine: Sendable {
    func load() async throws
    func shutdown() async
    func events() async -> AsyncStream<DownloadEvent>
    @discardableResult func add(_ request: NewDownload) async throws -> DownloadID
    func pause(_ id: DownloadID) async
    func resume(_ id: DownloadID) async
    func pauseAll() async
    func resumeAll() async
    func remove(_ id: DownloadID, deleteFiles: Bool) async
    func setMaxConcurrentDownloads(_ count: Int) async
    func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) async
}

extension DownloadManager: DownloadEngine {}
