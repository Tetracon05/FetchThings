import AppKit
import UniformTypeIdentifiers

/// Marks a drag that starts in this app. The window accepts links, text files and text dropped on it, so without a mark a
/// file dragged out of the list or the details pane and dropped back on the window (to change one's mind) would be read
/// as a file to look for links in, and end in a "No Links Found" alert.
enum OwnDrag {
    static let identifier = (Bundle.main.bundleIdentifier ?? "Downloader") + ".internal-drag"
    static let type = UTType(exportedAs: identifier)
    static var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(identifier) }
}
