import DownloadKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadTable: View {
    @Bindable var model: AppModel

    /// Marks the table so `QuickLookController` can find it among the window's AppKit views.
    static let accessibilityID = "downloads-table"

    var body: some View {
        Table(of: DownloadSnapshot.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            // The place in the queue. Sorting by it (the default) puts the list in the order downloads run in, and only
            // then can rows be dragged to change it.
            TableColumn("#", value: \.queueSortKey) { download in
                QueueCell(position: model.queuePositions[download.id], priority: download.priority)
            }
            .width(min: 40, ideal: 44, max: 72)

            TableColumn("Name", value: \.displayName) { download in
                NameCell(download: download)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Size", value: \.sizeSortKey) { download in
                Text(Formatters.size(download.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Progress", value: \.progressSortKey) { download in
                ProgressCell(download: download)
            }
            .width(min: 130, ideal: 170)

            TableColumn("Speed", value: \.bytesPerSecond) { download in
                Text(Formatters.speed(download.bytesPerSecond))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Time Left", value: \.etaSortKey) { download in
                Text(Formatters.eta(download.eta))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Status", value: \.statusSortKey) { download in
                StatusCell(download: download, text: model.statusText(of: download))
            }
            .width(min: 90, ideal: 140) // "Waiting for network" must fit
        } rows: {
            ForEach(model.visibleDownloads) { download in
                // A finished file can be dragged out of the list into Finder or any app that takes files; with several
                // rows selected the drag carries all of them. Rows still downloading have nothing to hand over.
                TableRow(download).itemProvider { model.dragProvider(for: download) }
            }
            // Rows dragged to a new place in the queue land between two rows.
            .onInsert(of: [QueueDrag.type]) { index, providers in model.dropInQueue(providers, atRow: index) }
        }
        // The stripes would run through the empty-state message and make it hard to read.
        .alternatingRowBackgrounds(model.visibleDownloads.isEmpty ? .disabled : .enabled)
        .contextMenu(forSelectionType: DownloadID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            primaryAction(ids)
        }
        // Delete only acts while the table has focus, so it cannot fire while typing in a text field.
        .onDeleteCommand { model.requestRemoval(model.selection) }
        // Space opens Quick Look on the selection, Option-Space in full screen, as in Finder.
        .onKeyPress(keys: [.space]) { press in
            QuickLookController.shared.toggle(for: model, fullScreen: press.modifiers.contains(.option))
            return .handled
        }
        .accessibilityIdentifier(Self.accessibilityID)
        .overlay {
            if model.visibleDownloads.isEmpty { emptyState }
        }
        .accessibilityLabel("Downloads")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.downloads.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Drop links or a text file here, paste a link, or add one yourself.")
            } actions: {
                Button("Add Download…") { model.presentAddSheet() }
                    .glassButton(prominent: true)
            }
        } else {
            ContentUnavailableView(
                "Nothing Here", systemImage: model.sidebarSelection.symbol,
                description: Text(model.sidebarSelection.emptyMessage)
            )
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<DownloadID>) -> some View {
        let targets = model.visibleDownloads.filter { ids.contains($0.id) }
        if !targets.isEmpty {
            if targets.contains(where: \.isPausable) {
                Button("Pause") { model.pause(ids) }
            }
            if targets.contains(where: \.isResumable) {
                Button(targets.allSatisfy { $0.state == .failed } ? "Retry" : "Resume") { model.resume(ids) }
            }
            if targets.count == 1, let only = targets.first, only.state == .completed {
                Button("Open") { model.open(only) }
            }
            if targets.contains(where: { model.availableFile(of: $0) != nil }) {
                Button("Quick Look") {
                    // Quick Look shows the selection. As in Finder, a row that is right-clicked without being selected
                    // becomes the selection first (SwiftUI passes the menu only that row, and leaves the selection alone).
                    model.selectIfNeeded(ids)
                    QuickLookController.shared.toggle(for: model)
                }
            }
            Button("Show in Finder") { model.revealInFinder(ids) }
            if targets.contains(where: { $0.state != .completed }) {
                Divider()
                Button("Move to Top") { model.moveToTop(ids) }
                Button("Move to Bottom") { model.moveToBottom(ids) }
                PriorityMenu(model: model, ids: ids)
                Divider()
            }
            Button(targets.count == 1 ? "Copy Link" : "Copy Links") { model.copyLinks(ids) }
            Divider()
            Button("Remove from List") { model.requestRemoval(ids) }
            if targets.contains(where: { $0.state == .completed }) {
                Button("Remove and Move File to Trash", role: .destructive) { model.requestRemoval(ids, trashFiles: true) }
            }
        }
    }

    /// Double-click or Return: open a finished file, or get a stopped download going again.
    private func primaryAction(_ ids: Set<DownloadID>) {
        let targets = model.visibleDownloads.filter { ids.contains($0.id) }
        if targets.count == 1, let only = targets.first, only.state == .completed {
            model.open(only)
        } else {
            model.resume(ids)
        }
    }
}

// MARK: Cells

private struct NameCell: View {
    let download: DownloadSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.icon(forFilename: download.displayName))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(download.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(download.url.absoluteString)
    }
}

private struct ProgressCell: View {
    let download: DownloadSnapshot
    /// `.increased` while the row is selected (drawn on the accent colour), where a blue bar would vanish.
    @Environment(\.backgroundProminence) private var prominence

    private var selected: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = download.fraction {
                ProgressBar(fraction: fraction, tint: tint, selected: selected)
            } else if download.state.isRunning {
                ProgressView() // size unknown: indeterminate
                    .tint(selected ? .white : tint)
            } else {
                ProgressBar(fraction: 0, tint: tint, selected: selected)
            }
            Text(Formatters.percent(download.fraction))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(spoken)
    }

    private var tint: Color { download.stateTint }

    private var spoken: String {
        var parts = [Formatters.percent(download.fraction)]
        if download.state == .downloading {
            if download.bytesPerSecond >= 1 { parts.append(Formatters.speed(download.bytesPerSecond)) }
            if let eta = download.eta { parts.append(String(localized: "\(Formatters.eta(eta)) remaining")) }
        }
        return parts.joined(separator: ", ")
    }
}

/// A bar made of Liquid Glass: a clear glass track with a tinted glass capsule for the part that is done. It is drawn
/// by hand because `ProgressView(value: 0)` draws a nub at the start, which looked like a glitch on every queued row.
struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    /// A selected row is drawn on the accent colour, where the tint would vanish, so the fill turns white.
    let selected: Bool

    private let height: CGFloat = 8

    var body: some View {
        // Two separate glass shapes, not a `GlassGroup`: inside one container the fill blends into the track and its
        // end goes soft instead of staying a crisp round cap.
        Capsule()
            .fill(.clear)
            .frame(height: height)
            .glassSurface(.capsule)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    if fraction > 0 {
                        Capsule()
                            .fill(.clear)
                            .frame(width: max(height, proxy.size.width * min(fraction, 1)), height: height)
                            .glassSurface(.capsule, tint: selected ? .white : tint)
                    }
                }
            }
            .frame(height: height)
    }
}

/// The "#" column: the place in the queue, with a mark for a priority that is not normal.
private struct QueueCell: View {
    let position: Int?
    let priority: DownloadPriority

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = priority.symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(priority == .high ? Color.orange : Color.secondary)
            }
            Text(position.map { "\($0)" } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(position == nil ? "" : String(localized: "Queue Position"))
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        guard let position else { return "" }
        return priority == .normal ? "\(position)" : String(localized: "\(position), \(priority.title) priority")
    }
}

/// The priority of the downloads it is opened for, as a submenu with a check mark on the one they share.
struct PriorityMenu: View {
    let model: AppModel
    let ids: Set<DownloadID>

    var body: some View {
        let current = model.priority(of: ids)
        Menu("Priority") {
            ForEach(DownloadPriority.allCases.reversed(), id: \.self) { priority in
                Toggle(priority.title, isOn: Binding(get: { current == priority }, set: { _ in model.setPriority(priority, for: ids) }))
            }
        }
    }
}

private struct StatusCell: View {
    let download: DownloadSnapshot
    /// What the row says: the state's name, or that it waits for the network.
    let text: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(text)
            .foregroundStyle(style)
            .fontWeight(download.state == .failed && prominence == .increased ? .semibold : .regular)
            .help(download.failure ?? text)
            .accessibilityValue(download.failure.map { "\(text). \($0)" } ?? text)
    }

    /// Red on the blue selection is hard to read, so a selected failed row switches to bold white.
    private var style: AnyShapeStyle {
        guard download.state == .failed else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(prominence == .increased ? Color.white : Color.red)
    }
}

/// File-type icons from the system, cached per extension.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forFilename name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }

    private static var fileCache: [String: NSImage] = [:]

    /// The icon of a finished file itself, which is more specific than its type where the file carries a custom one
    /// (a disk image, an app). Falls back to the type's icon while the file is not there.
    static func icon(forFile url: URL, fallbackName: String) -> NSImage {
        if let cached = fileCache[url.path] { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return icon(forFilename: fallbackName) }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if fileCache.count > 200 { fileCache.removeAll() }
        fileCache[url.path] = icon
        return icon
    }
}
