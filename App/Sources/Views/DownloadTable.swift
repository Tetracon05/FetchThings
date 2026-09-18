import DownloadKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadTable: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.visibleDownloads, selection: $model.selection, sortOrder: $model.sortOrder) {
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
        }
        .contextMenu(forSelectionType: DownloadID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            primaryAction(ids)
        }
        // Delete only acts while the table has focus, so it cannot fire while typing in a text field.
        .onDeleteCommand { model.requestRemoval(model.selection) }
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
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Nothing Here", systemImage: model.sidebarSelection.symbol,
                description: Text("No \(model.sidebarSelection.title.lowercased()) downloads.")
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

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = download.fraction {
                ProgressView(value: fraction)
            } else if download.state.isRunning {
                ProgressView() // size unknown: indeterminate
            } else {
                ProgressView(value: 0)
            }
            Text(Formatters.percent(download.fraction))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .tint(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(spoken)
    }

    private var tint: Color {
        switch download.state {
        case .failed: .red
        case .completed: .green
        case .paused, .queued: .gray
        default: .accentColor
        }
    }

    private var spoken: String {
        var parts = [Formatters.percent(download.fraction)]
        if download.state == .downloading {
            if download.bytesPerSecond >= 1 { parts.append(Formatters.speed(download.bytesPerSecond)) }
            if let eta = download.eta { parts.append("\(Formatters.eta(eta)) remaining") }
        }
        return parts.joined(separator: ", ")
    }
}

private struct StatusCell: View {
    let download: DownloadSnapshot

    var body: some View {
        Text(download.statusText)
            .foregroundStyle(download.state == .failed ? Color.red : Color.secondary)
            .help(download.failure ?? download.statusText)
            .accessibilityValue(download.failure.map { "\(download.statusText). \($0)" } ?? download.statusText)
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
}
