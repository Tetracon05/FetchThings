import AppKit
import DownloadKit

/// The slice of the clipboard the app cares about, so the watcher can be tested without a real pasteboard.
@MainActor
protocol PasteboardSource {
    var changeCount: Int { get }
    /// `http(s)` links currently on the clipboard.
    func links() async -> [URL]
    /// Puts text on the clipboard and returns the new change count, so the app can ignore its own copy.
    func copy(_ text: String) -> Int
}

@MainActor
struct SystemPasteboard: PasteboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func links() async -> [URL] {
        let pasteboard = NSPasteboard.general
        // Peeking at the clipboard must not trigger the "app pasted from other apps" notice, so on
        // systems that can tell us whether it holds a web address, only read the text when it does.
        if #available(macOS 15.4, *) {
            let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
            guard patterns?.contains(\.probableWebURL) == true else { return [] }
        }
        guard let text = pasteboard.string(forType: .string) else { return [] }
        return LinkParser.urls(in: text)
    }

    func copy(_ text: String) -> Int {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return NSPasteboard.general.changeCount
    }
}
