import AppKit
import QuickLookUI

/// Quick Look for the selected downloads, as in Finder: Space opens the preview panel over the window, Space or Esc
/// closes it, the arrow keys move the selection while it is open, and the panel follows.
///
/// Quick Look decides who runs its one shared panel by asking the responder chain. The table is a SwiftUI view, so the
/// app delegate answers (`AppDelegate`), and this object supplies the files and handles the panel's events while it
/// has control. Setting the data source without that made Quick Look complain that the panel had no controller.
@MainActor
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    private weak var model: AppModel?
    private var items: [PreviewItem] = []

    private var panel: QLPreviewPanel? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil }
    private var isOpen: Bool { panel?.isVisible ?? false }

    /// Space: opens the panel for the selected files, or closes it when it is already open. Option-Space goes straight
    /// to full screen, as in Finder. Does nothing when no selected download has a finished file.
    func toggle(for model: AppModel, fullScreen: Bool = false) {
        self.model = model
        if isOpen {
            panel?.orderOut(nil)
            return
        }
        let fresh = model.quickLookItems
        guard !fresh.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = fresh.map(PreviewItem.init)
        panel.makeKeyAndOrderFront(nil) // Quick Look now asks who controls it, and `attach` answers
        if fullScreen { panel.enterFullScreenMode(nil, withOptions: nil) }
    }

    /// The panel has been handed to us: it shows the files gathered by `toggle`.
    func attach(to panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func detach(from panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// The selection changed while the panel is open: show the new files, or close when there is nothing to show.
    func selectionChanged(in model: AppModel) {
        guard isOpen, let panel else { return }
        let fresh = model.quickLookItems
        guard !fresh.isEmpty else {
            panel.orderOut(nil)
            return
        }
        guard fresh != items.map(\.item) else { return }
        items = fresh.map(PreviewItem.init)
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    // MARK: Table access

    /// The downloads table, for the zoom animation and for keeping the selected row in view. Nil if it is not found,
    /// in which case both are skipped.
    private var table: NSTableView? {
        guard let root = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.sceneID })?.contentView else { return nil }
        return Self.findTable(in: root)
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.accessibilityIdentifier() == DownloadTable.accessibilityID { return table }
        for child in view.subviews { if let found = findTable(in: child) { return found } }
        return nil
    }

    private func row(of item: PreviewItem) -> Int? {
        model?.visibleDownloads.firstIndex { $0.id == item.item.id }
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let item: QuickLookItem
    init(_ item: QuickLookItem) { self.item = item }
    var previewItemURL: URL! { item.url }
    var previewItemTitle: String! { item.title }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDelegate {
    /// The arrow keys, while the panel is the key window: with one file showing they move the selection in the list
    /// (as Finder's list does); with several the panel pages through them itself.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // One file showing *and* one row selected: with a wider selection the arrows have no row to move (and the
        // panel must not swallow them for nothing).
        guard event.type == .keyDown, items.count == 1, let model, model.selection.count == 1 else { return false }
        let offset: Int
        switch event.keyCode {
        case 126, 123: offset = -1 // up, left
        case 125, 124: offset = 1 // down, right
        default: return false
        }
        model.moveSelection(by: offset)
        if let only = model.selection.first, let row = model.visibleDownloads.firstIndex(where: { $0.id == only }) {
            table?.scrollRowToVisible(row)
        }
        return true
    }

    /// Where the preview grows out of and shrinks back into: the file's icon in its row. Zero (no animation) when the
    /// row is not on screen.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let item = item as? PreviewItem, let table, let window = table.window, let row = row(of: item),
              table.visibleRect.intersects(table.rect(ofRow: row)) else { return .zero }
        let cell = table.frameOfCell(atColumn: 0, row: row)
        let icon = NSRect(x: cell.minX, y: cell.midY - 9, width: 18, height: 18)
        return window.convertToScreen(table.convert(icon, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let item = item as? PreviewItem else { return nil }
        return NSWorkspace.shared.icon(forFile: item.item.url.path)
    }
}
