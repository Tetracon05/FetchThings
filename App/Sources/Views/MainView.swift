import DownloadKit
import SwiftUI

/// Widths that must add up: the widest the sidebar can get, the narrowest table, and the details pane with its
/// margins have to fit in `minWindowWidth` together, or the split view overflows the window (see CLAUDE.md).
enum MainWindowLayout {
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarMaxWidth: CGFloat = 250
    static let tableMinWidth: CGFloat = 320
    static let paneWidth: CGFloat = 272
    /// The gap around the floating glass pane, on each side.
    static let paneInset: CGFloat = 8
    static let minWindowWidth: CGFloat = 860
    static let minWindowHeight: CGFloat = 460
}

struct MainView: View {
    @Bindable var model: AppModel
    @FocusState private var tableFocused: Bool
    /// The toolbar search field's width (see `SearchFieldLayout`). Only the resulting width is kept, not the width of the
    /// area it is worked out from: the toolbar was laid out wrongly (the field partly outside the window) when this was
    /// updated at launch with a value that came out the same.
    @State private var searchFieldWidth = SearchFieldLayout.widest

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: MainWindowLayout.sidebarMinWidth, ideal: 210, max: MainWindowLayout.sidebarMaxWidth)
        } detail: {
            // A fixed-width pane in a plain HStack: every pane has a size that cannot conflict with the window's
            // minimum. (`.inspector` looped the layout at minimum width, and `HSplitView` centred the table
            // vertically and overflowed the window when the pane opened.)
            HStack(spacing: 0) {
                DownloadTable(model: model)
                    .focused($tableFocused)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            if let block = model.networkBanner {
                                NetworkBanner(block: block, downloadAnyway: model.downloadAnyway)
                            }
                            if let links = model.clipboardOffer {
                                ClipboardBanner(links: links, add: model.acceptClipboardOffer, dismiss: model.dismissClipboardOffer)
                            }
                        }
                    }
                    .frame(minWidth: MainWindowLayout.tableMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    // A click in the table must take keyboard focus from the search field, or Delete and the arrow
                    // keys keep going to the field after the user has searched. (The click still selects the row.)
                    .simultaneousGesture(TapGesture().onEnded { tableFocused = true })
                if model.showInspector {
                    // A floating glass card beside the table rather than a flat column with a divider.
                    InspectorView(model: model)
                        .frame(width: MainWindowLayout.paneWidth)
                        .frame(maxHeight: .infinity)
                        .glassSurface(.rect(cornerRadius: 22))
                        .padding(MainWindowLayout.paneInset)
                }
            }
            .onGeometryChange(for: CGFloat.self) { SearchFieldLayout.width(detailAreaWidth: $0.size.width) } action: { searchFieldWidth = $0 }
        }
        .navigationTitle(model.sidebarSelection.title)
        .navigationSubtitle(subtitle)
        .onChange(of: model.selection) { QuickLookController.shared.selectionChanged(in: model) }
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
        .onDrop(of: [.url, .plainText], delegate: IncomingDropDelegate(model: model))
        .pasteDestination(for: String.self) { strings in
            model.handleText(strings.joined(separator: "\n"))
        }
    }

    private var subtitle: String {
        let running = model.runningCount
        var parts = [String(localized: "\(model.visibleDownloads.count) downloads")]
        if running > 0 { parts.append(String(localized: "\(Formatters.speed(model.totalBytesPerSecond)) · \(running) active")) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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

            // A Button, not a Toggle: a toolbar Toggle reaches VoiceOver without any label.
            Button { model.showInspector.toggle() } label: {
                Label("Details", systemImage: "sidebar.trailing")
                    .symbolVariant(model.showInspector ? .fill : .none)
            }
            .accessibilityValue(model.showInspector ? "Shown" : "Hidden")
            .help("Show or hide the details pane")
        }
        searchItem
    }

    /// As wide as the details card below it, so the field does not straddle the edge between table and card. It has its
    /// own glass (see `ToolbarSearchField`); by default the toolbar would merge it into the buttons' capsule.
    @ToolbarContentBuilder
    private var searchItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { searchField }
            .outsideSharedGlass()
    }

    private var searchField: some View {
        ToolbarSearchField(
            text: $model.searchText, focusRequested: $model.isSearchFocused,
            width: searchFieldWidth
        ) { tableFocused = true }
    }
}

/// A slim glass bar under the toolbar: an icon disc, a message, and buttons for what the user can do about it.
struct BannerBar<Actions: View>: View {
    let symbol: String
    let tint: Color
    let message: String
    var lines = 1
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            IconChip(symbol: symbol, tint: tint, size: 24)
            Text(message)
                .lineLimit(lines)
                .truncationMode(.middle)
            Spacer()
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassSurface(.capsule)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

struct ClipboardBanner: View {
    let links: [URL]
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        BannerBar(symbol: "link", tint: .accentColor, message: message) {
            Button("Add…", action: add)
                .glassButton(prominent: true)
            Button("Dismiss", action: dismiss)
                .glassButton()
        }
    }

    private var message: String {
        guard let first = links.first else { return "" }
        return links.count == 1
            ? String(localized: "Link on the clipboard: \(first.absoluteString)")
            : String(localized: "\(links.count) links on the clipboard, starting with \(first.absoluteString)")
    }
}

/// Says that downloads are waiting for the connection, and why. Offline there is nothing to do; on a connection the
/// user asked to keep downloads off, they can go ahead anyway.
struct NetworkBanner: View {
    let block: NetworkBlock
    let downloadAnyway: () -> Void

    var body: some View {
        BannerBar(symbol: symbol, tint: .orange, message: message, lines: 2) {
            if block != .offline {
                Button("Download Anyway", action: downloadAnyway)
                    .glassButton(prominent: true)
            }
        }
    }

    private var symbol: String {
        switch block {
        case .offline: "wifi.slash"
        case .expensive: "personalhotspot"
        case .constrained: "leaf.fill"
        }
    }

    private var message: String {
        switch block {
        case .offline: String(localized: "You’re offline. Downloads wait here and continue when the connection is back.")
        case .expensive: String(localized: "This connection may be metered (a Personal Hotspot or cellular). Downloads are waiting.")
        case .constrained: String(localized: "Low Data Mode is on for this network. Downloads are waiting.")
        }
    }
}
