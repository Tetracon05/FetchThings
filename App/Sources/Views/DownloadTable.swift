import DownloadKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadTable: View {
    @Bindable var model: AppModel

    /// Marks the table so `QuickLookController` can find it among the window's AppKit views.
    static let accessibilityID = "downloads-table"

    var body: some View {
        Table(of: DownloadSnapshot.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.displayName) { download in
                NameCell(download: download)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Size", value: \.sizeSortKey) { download in
                Text(Formatters.size(download.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Progress", value: \.progressSortKey) { download in
                ProgressCell(download: download)
            }
            .width(min: 130, ideal: 190)

            TableColumn("Speed", value: \.bytesPerSecond) { download in
                Text(Formatters.speed(download.bytesPerSecond))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95)

            TableColumn("Time Left", value: \.etaSortKey) { download in
                Text(Formatters.eta(download.eta))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Status", value: \.statusSortKey) { download in
                StatusCell(download: download)
            }
            .width(min: 90, ideal: 110)
        } rows: {
            ForEach(model.visibleDownloads) { download in
                // A finished file can be dragged out of the list into Finder or any app that takes files; with several
                // rows selected the drag carries all of them. Rows still downloading have nothing to hand over.
                TableRow(download).itemProvider { model.dragProvider(for: download) }
            }
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
                description: Text("No \(model.sidebarSelection.title.localizedLowercase) downloads.")
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
                Button("Quick Look") { QuickLookController.shared.toggle(for: model) }
            }
            Button("Show in Finder") { model.revealInFinder(ids) }
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

private struct StatusCell: View {
    let download: DownloadSnapshot
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(download.statusText)
            .foregroundStyle(style)
            .fontWeight(download.state == .failed && prominence == .increased ? .semibold : .regular)
            .help(download.failure ?? download.statusText)
            .accessibilityValue(download.failure.map { "\(download.statusText). \($0)" } ?? download.statusText)
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
