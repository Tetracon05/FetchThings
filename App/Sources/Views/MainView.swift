import DownloadKit
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            DownloadTable(model: model)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let links = model.clipboardOffer {
                        ClipboardBanner(links: links, add: model.acceptClipboardOffer, dismiss: model.dismissClipboardOffer)
                    }
                }
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
                }
        }
        .navigationTitle(model.sidebarSelection.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search downloads")
        .toolbar { toolbar }
        .sheet(isPresented: $model.showAddSheet, onDismiss: model.resetDraft) { AddDownloadSheet(model: model) }
        .confirmationDialog(
            model.pendingRemoval?.title ?? "",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { _ in
            Button("Remove", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        // Links, text files and text can be dropped or pasted anywhere in the window. They only propose
        // downloads: the Add sheet opens filled in, and nothing starts until the user confirms.
        .dropDestination(for: URL.self) { urls, _ in
            model.handleIncoming(urls: urls)
            return true
        }
        .dropDestination(for: String.self) { strings, _ in
            model.handleText(strings.joined(separator: "\n"))
            return true
        }
        .pasteDestination(for: String.self) { strings in
            model.handleText(strings.joined(separator: "\n"))
        }
    }

    private var subtitle: String {
        let running = model.runningCount
        var parts = ["\(model.visibleDownloads.count) \(model.visibleDownloads.count == 1 ? "download" : "downloads")"]
        if running > 0 { parts.append("\(Formatters.speed(model.totalBytesPerSecond)) · \(running) active") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.presentAddSheet() } label: {
                Label("Add Download", systemImage: "plus")
            }
            .help("Add a download (⌘N)")

            Button { model.pauseSelection() } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!model.canPauseSelection)
            .help("Pause the selected downloads (⌥⌘P)")

            Button { model.resumeSelection() } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(!model.canResumeSelection)
            .help("Resume the selected downloads, or retry failed ones (⌥⌘R)")

            Button { model.revealInFinder(model.selection) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(!model.canRevealSelection)
            .help("Show in Finder (⌘R)")

            Button { model.requestRemoval(model.selection) } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(model.selectedDownloads.isEmpty)
            .help("Remove from the list (Delete). Finished files are kept; partly downloaded data is deleted after you confirm.")

            Toggle(isOn: $model.showInspector) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }
}

struct ClipboardBanner: View {
    let links: [URL]
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Add…", action: add)
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        guard let first = links.first else { return "" }
        return links.count == 1
            ? "Link on the clipboard: \(first.absoluteString)"
            : "\(links.count) links on the clipboard, starting with \(first.absoluteString)"
    }
}
