import DownloadKit
import Synchronization

/// Where the engine's events wait for the next refresh: only the newest event per download is kept. It is filled
/// from a task that is not on the main actor, so a busy UI cannot let events pile up in the engine's stream.
final class EventInbox: Sendable {
    private let events = Mutex<[DownloadID: DownloadEvent]>([:])

    func put(_ event: DownloadEvent) {
        let id: DownloadID = switch event {
        case .snapshot(let snapshot): snapshot.id
        case .removed(let id): id
        }
        events.withLock { $0[id] = event }
    }

    func take() -> [DownloadEvent] {
        events.withLock { stored in
            defer { stored.removeAll() }
            return Array(stored.values)
        }
    }
}
