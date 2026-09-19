import DownloadKit
import QuickLookThumbnailing
import SwiftUI

/// Previews of finished files as Finder shows them: a frame of a video, a photo, the first page of a PDF.
@MainActor
enum FileThumbnails {
    private static var cache: [String: NSImage] = [:]

    private static var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// One entry per file *version*: a file replaced at the same path (removed, then downloaded again) must not show
    /// the old picture.
    private static func key(_ url: URL, _ size: CGSize) -> String {
        // Not `URL.resourceValues`: a URL object remembers what it read, so it would keep reporting the old date.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(Int(size.width))x\(Int(size.height))"
    }

    static func cached(_ url: URL, size: CGSize) -> NSImage? {
        cache[key(url, size)]
    }

    /// The preview of the file's contents, or nil when the system has none for this kind of file (a disk image, an
    /// archive), in which case the caller keeps the file's icon. Never throws: a missing preview is not an error.
    static func load(_ url: URL, size: CGSize) async -> NSImage? {
        let key = key(url, size)
        if let hit = cache[key] { return hit }
        // `.icon` is left out on purpose: the icon path (`FileIcons`) already covers files without a preview.
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        if cache.count > 100 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The picture of one download: a preview of the finished file's contents, and the icon of its type until there is one
/// (while it downloads, or when the system cannot draw a preview of that kind of file).
struct DownloadPicture: View {
    /// The room the details pane gives the picture of a single download.
    static let headerBox = CGSize(width: 232, height: 148)

    let download: DownloadSnapshot
    /// The most room a preview may take; it keeps its proportions inside it.
    let box: CGSize
    /// The side of the icon that stands in when there is no preview.
    let iconSide: CGFloat

    /// A preview belongs to the file it was made for, so a stale one is never shown for another selection.
    @State private var preview: (url: URL, image: NSImage)?

    private var fileURL: URL? { download.state == .completed ? download.finalURL : nil }

    init(download: DownloadSnapshot, box: CGSize, iconSide: CGFloat) {
        self.download = download
        self.box = box
        self.iconSide = iconSide
        // Coming back to a file that was already drawn must not flash its icon first.
        if download.state == .completed, let url = download.finalURL, let image = FileThumbnails.cached(url, size: box) {
            _preview = State(initialValue: (url, image))
        }
    }

    var body: some View {
        ZStack {
            if let fileURL, let preview, preview.url == fileURL {
                Image(nsImage: preview.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSide, height: iconSide)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
        }
        .frame(width: box.width, height: box.height)
        .task(id: fileURL) {
            guard let url = fileURL else { return }
            if preview?.url == url { return }
            guard let image = await FileThumbnails.load(url, size: box) else { return }
            withAnimation(.easeOut(duration: 0.15)) { preview = (url, image) }
        }
        .accessibilityHidden(true) // the name is spoken by the rows and the Name field
    }

    private var icon: NSImage {
        if let fileURL { return FileIcons.icon(forFile: fileURL, fallbackName: download.displayName) }
        return FileIcons.icon(forFilename: download.displayName)
    }
}

/// Several selected downloads as a pile of pictures, the way Finder shows a multiple selection: the first one on top,
/// the next ones fanned out behind it, and a badge with the count.
struct DownloadStack: View {
    let downloads: [DownloadSnapshot]

    /// How many pictures the pile shows; more would only add clutter.
    static let depth = 4
    static let cardBox = CGSize(width: 130, height: 100)

    /// Turn and shift of the card at each depth, the top one first.
    private static let poses: [(angle: Double, x: CGFloat, y: CGFloat)] = [
        (0, 0, 0), (-8, -14, 4), (7, 14, 3), (-15, -8, 10),
    ]

    var body: some View {
        let shown = Array(downloads.prefix(Self.depth))
        ZStack {
            // The last one is drawn first, so the first ends up on top.
            ForEach(Array(shown.enumerated()).reversed(), id: \.element.id) { depth, download in
                let pose = Self.poses[depth]
                DownloadPicture(download: download, box: Self.cardBox, iconSide: 84)
                    .rotationEffect(.degrees(pose.angle))
                    .offset(x: pose.x, y: pose.y)
            }
        }
        .frame(width: 190, height: 150)
        .overlay(alignment: .bottomTrailing) {
            Text(downloads.count, format: .number)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .glassSurface(.capsule, tint: .accentColor)
        }
        .accessibilityHidden(true) // the title below says how many are selected
    }
}

// MARK: Dragging the picture out

/// Makes the view it is laid over a source for dragging files out: hold the picture and drag, and the files it stands
/// for go to Finder or any other app that takes files, like the proxy icon of a document.
///
/// It is an AppKit drag session rather than SwiftUI's `onDrag`: that carries exactly one item, so a pile of several files
/// could not be dragged, and it copies every dragged file into a cache folder first. Here each file is handed over by
/// its own address.
struct FileDragSource: NSViewRepresentable {
    struct Item {
        let url: URL
        /// What is drawn under the pointer while dragging.
        let image: NSImage
    }

    /// The files to hand over, asked for when the drag starts (they may be gone by then). Nothing to hand over: no drag.
    let items: @MainActor () -> [Item]

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.items = items
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.items = items
    }

    /// The drag items for `downloads`: their finished files, each pictured by its preview if one was drawn at `box`
    /// (the size the pane showed it at), else by its icon.
    @MainActor
    static func items(for downloads: [DownloadSnapshot], in model: AppModel, box: CGSize) -> [Item] {
        model.dragFiles(of: downloads).enumerated().map { index, url in
            // Only the first few need a picture: a pile of thousands would take long to build and only the top shows.
            let image = index < DragSourceView.pictured
                ? FileThumbnails.cached(url, size: box) ?? NSWorkspace.shared.icon(forFile: url.path)
                : NSImage()
            return Item(url: url, image: image)
        }
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    /// How many of the dragged files get a picture of their own under the pointer.
    static let pictured = 4
    private static let longestSide: CGFloat = 96
    private static let dragThreshold: CGFloat = 4

    var items: @MainActor () -> [FileDragSource.Item] = { [] }
    private var pressedAt: NSPoint?

    // Dragging must work on the first press in a window that is not yet active, and must not move the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
        pressedAt = nil
        let dragged = items()
        guard !dragged.isEmpty else { return }

        let draggingItems = dragged.enumerated().map { index, item -> NSDraggingItem in
            let dragging = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: item.url))
            if index < Self.pictured {
                let size = Self.fitted(item.image.size)
                // Centred on the pointer, each picture nudged a little so the top of a pile shows the ones under it.
                let nudge = CGFloat(index) * 5
                let frame = NSRect(x: start.x - size.width / 2 + nudge, y: start.y - size.height / 2 - nudge, width: size.width, height: size.height)
                dragging.setDraggingFrame(frame, contents: item.image)
            } else {
                dragging.setDraggingFrame(NSRect(x: start.x, y: start.y, width: 1, height: 1), contents: nil)
            }
            return dragging
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) { pressedAt = nil }

    /// The file's address, as any file drag carries it, plus the mark that lets this app's own window refuse the drag.
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(Data(), forType: OwnDrag.pasteboardType)
        return item
    }

    /// Copy only: the download stays where it is, so the list keeps pointing at a file that exists.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: longestSide, height: longestSide) }
        let scale = longestSide / max(size.width, size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}
