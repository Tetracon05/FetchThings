import AppKit
import DownloadKit
import UniformTypeIdentifiers

/// Marks a drag that starts in this app. The window accepts links, text files and text dropped on it, so without a mark a
/// file dragged out of the list or the details pane and dropped back on the window (to change one's mind) would be read
/// as a file to look for links in, and end in a "No Links Found" alert.
enum OwnDrag {
    static let identifier = (Bundle.main.bundleIdentifier ?? "FetchThings") + ".internal-drag"
    static let type = UTType(exportedAs: identifier)
    static var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(identifier) }
}

/// What a row dragged to a new place in the queue carries: the download's id, visible only inside this app.
enum QueueDrag {
    static let identifier = (Bundle.main.bundleIdentifier ?? "FetchThings") + ".queue-item"
    static let type = UTType(exportedAs: identifier)

    /// A provider for dragging `id`; it also carries the `OwnDrag` mark, so dropping it back on the window (which takes
    /// links and files) is refused rather than read as one.
    static func provider(for id: DownloadID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: OwnDrag.identifier, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    /// The download a provider from `provider(for:)` stands for.
    @MainActor
    static func id(from provider: NSItemProvider) async -> DownloadID? {
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in continuation.resume(returning: data) }
        }
        return data.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) }
    }
}
