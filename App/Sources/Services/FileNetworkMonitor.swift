import DownloadKit
import Foundation

/// UI testing only (see `AppEnvironment.networkMonitor`): a network whose state is a word in a file, read twice a second.
final class FileNetworkMonitor: NetworkMonitoring {
    private let file: URL

    init(file: URL) { self.file = file }

    func currentStatus() async -> NetworkStatus { read() }

    func changes() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let file = file
            let task = Task {
                var last: NetworkStatus?
                while !Task.isCancelled {
                    let status = Self.status(in: file)
                    if status != last {
                        last = status
                        continuation.yield(status)
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read() -> NetworkStatus { Self.status(in: file) }

    private static func status(in file: URL) -> NetworkStatus {
        switch (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "offline": .offline
        case "expensive": NetworkStatus(isConnected: true, isExpensive: true)
        case "constrained": NetworkStatus(isConnected: true, isConstrained: true)
        default: .online
        }
    }
}
