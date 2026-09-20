import Foundation
import Network
import Synchronization

/// The real network monitor: `NWPathMonitor`, reduced to what the engine cares about.
public final class SystemNetworkMonitor: NetworkMonitoring {
    private struct State {
        var latest: NetworkStatus?
        var waiting: [CheckedContinuation<NetworkStatus, Never>] = []
        var subscribers: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let monitor = NWPathMonitor()

    /// How long to wait for the system's first reading before assuming the network is fine. It normally comes within
    /// milliseconds; a monitor that never answered must not keep the app from starting its downloads.
    private static let firstReadingTimeout: TimeInterval = 1

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(NetworkStatus(isConnected: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained))
        }
        monitor.start(queue: DispatchQueue(label: "DownloadKit.network", qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.firstReadingTimeout) { [weak self] in
            self?.updateIfNothingYet(.online)
        }
    }

    deinit {
        monitor.cancel()
        state.withLock { for continuation in $0.subscribers.values { continuation.finish() } }
    }

    public func currentStatus() async -> NetworkStatus {
        await withCheckedContinuation { continuation in
            let answer = state.withLock { state -> NetworkStatus? in
                if let latest = state.latest { return latest }
                state.waiting.append(continuation)
                return nil
            }
            if let answer { continuation.resume(returning: answer) }
        }
    }

    public func changes() -> AsyncStream<NetworkStatus> {
        let (stream, continuation) = AsyncStream<NetworkStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        let latest = state.withLock { state -> NetworkStatus? in
            state.subscribers[token] = continuation
            return state.latest
        }
        if let latest { continuation.yield(latest) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.subscribers[token] = nil }
        }
        return stream
    }

    private func update(_ status: NetworkStatus) {
        let (waiting, subscribers) = state.withLock { state -> ([CheckedContinuation<NetworkStatus, Never>], [AsyncStream<NetworkStatus>.Continuation]) in
            state.latest = status
            defer { state.waiting = [] }
            return (state.waiting, Array(state.subscribers.values))
        }
        for continuation in waiting { continuation.resume(returning: status) }
        for continuation in subscribers { continuation.yield(status) }
    }

    private func updateIfNothingYet(_ status: NetworkStatus) {
        guard state.withLock({ $0.latest == nil }) else { return }
        update(status)
    }
}
