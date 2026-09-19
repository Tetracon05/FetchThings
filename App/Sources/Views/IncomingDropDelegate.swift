import SwiftUI
import UniformTypeIdentifiers

/// What the main window does with something dropped on it: links, text files and text turn into a filled-in Add sheet.
/// A drag that started in this app is refused (`OwnDrag`): dropping a file back on the window is taking the drag back,
/// not offering the file as a list of links, so the drag just slides back.
struct IncomingDropDelegate: DropDelegate {
    let model: AppModel
    /// Follows whether an acceptable drag is over the target, for a view that lights up when it is.
    var isTargeted: Binding<Bool>?

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { isTargeted?.wrappedValue = true }
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [OwnDrag.type])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.url, .plainText])
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            var strings: [String] = []
            for provider in providers {
                // Judged by what the item really is: a provider of plain text can also be *read* as a URL, which would
                // turn every text drag into a "no links" complaint about a link that is not there.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await Self.load(URL.self, from: provider) { urls.append(url) }
                } else if let text = await Self.load(String.self, from: provider) {
                    strings.append(text)
                }
            }
            // A link dragged from a browser also offers its address as text; the link is the better reading.
            if !urls.isEmpty {
                model.handleIncoming(urls: urls)
            } else if !strings.isEmpty {
                model.handleText(strings.joined(separator: "\n"))
            }
        }
        return true
    }

    /// One dropped item read as `T`, or nil if it cannot be.
    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in continuation.resume(returning: object) }
        }
    }
}
