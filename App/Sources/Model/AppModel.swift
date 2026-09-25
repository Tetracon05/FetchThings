import AppKit
import DownloadKit
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.example.FetchThings", category: "model")

/// Everything the window shows, and every action it can take. The engine's events are batched, so the
/// views are refreshed a few times a second instead of on every progress tick.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    @ObservationIgnored private let engine: any DownloadEngine
    @ObservationIgnored private let pasteboard: any PasteboardSource

    private(set) var downloads: [DownloadID: DownloadSnapshot] = [:]
    /// `downloads` after the sidebar filter, search and sort. Recomputed when any of them changes.
    private(set) var visibleDownloads: [DownloadSnapshot] = []

    var sidebarSelection: SidebarItem = .all { didSet { recomputeVisible() } }
    var searchText = "" { didSet { recomputeVisible() } }
    /// By the queue unless the user picks another column: top to bottom is the order downloads run in.
    var sortOrder: [KeyPathComparator<DownloadSnapshot>] = [KeyPathComparator(\.queueSortKey)] {
        didSet { recomputeVisible() }
    }
    /// The place of each download that is not finished in the queue, from 1: what the "#" column shows.
    private(set) var queuePositions: [DownloadID: Int] = [:]
    /// Always a subset of `visibleDownloads`: a row that is filtered out is deselected, so no action can
    /// reach a download the user cannot see.
    var selection: Set<DownloadID> = []
    var showInspector = false
    /// A one-shot request to focus the search field in the toolbar (⌘F); the main view acts on it and resets it.
    var isSearchFocused = false

    /// The connection, and whether the engine is holding downloads back because of it (see `NetworkPolicy`).
    private(set) var network = NetworkState.unrestricted

    var showAddSheet = false
    /// A remark for the Add sheet to show under its links field (see `report`); the sheet takes it and clears it.
    var sheetNote: String?
    var draft: AddDraft
    var alert: AlertMessage?
    var pendingRemoval: PendingRemoval?
    /// Links noticed on the clipboard, offered (not added) to the user.
    private(set) var clipboardOffer: [URL]?

    /// Called when a download reaches `.completed` during this session; Phase 3 hooks notifications and the Dock here.
    @ObservationIgnored var onCompleted: ((DownloadSnapshot) -> Void)?
    /// The clipboard is only looked at while the app is frontmost. Replaceable for tests.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive == true }
    /// Moves a finished file to the Trash. Replaceable for tests.
    @ObservationIgnored var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    @ObservationIgnored private let inbox = EventInbox()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastSeenClipboardChange: Int
    /// Downloads that completed before this moment were restored from disk, not finished just now.
    @ObservationIgnored private let startedAt = Date()

    init(engine: any DownloadEngine, settings: AppSettings, pasteboard: any PasteboardSource = SystemPasteboard()) {
        self.engine = engine
        self.settings = settings
        self.pasteboard = pasteboard
        draft = AddDraft(folder: settings.downloadFolder, segmentCount: settings.segmentCount, userAgent: settings.defaultUserAgent)
        lastSeenClipboardChange = pasteboard.changeCount
    }

    // MARK: Lifecycle

    /// Applies settings, loads persisted downloads, and starts following the engine.
    func start() {
        guard tasks.isEmpty else { return }
        let engine = engine
        let inbox = inbox
        // Not on the main actor: draining the engine's stream must not depend on the UI keeping up.
        tasks.append(Task.detached { [weak self] in
            // Limits first: restored downloads start the moment they are loaded and must already be throttled.
            await self?.applyEngineSettings()
            do { try await engine.load() } catch { await self?.reportRestoreFailure(error) }
            for await event in await engine.events() { inbox.put(event) }
        })
        tasks.append(Task { [weak self] in
            for await state in await engine.networkStates() { self?.network = state }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.flushEvents()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.checkClipboard()
            }
        })
    }

    var isStarted: Bool { !tasks.isEmpty }

    private func reportRestoreFailure(_ error: any Error) {
        alert = AlertMessage(title: String(localized: "Couldn’t Restore Downloads"), message: error.localizedDescription)
    }

    /// Stops following the engine and stops running transfers, keeping their progress.
    func shutdown() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        await engine.shutdown()
    }

    func applyEngineSettings() async {
        await engine.setMaxConcurrentDownloads(settings.maxConcurrentDownloads)
        await engine.setNetworkPolicy(settings.networkPolicy)
        let limit = settings.globalSpeedLimit
        log.info("Speed mode \(self.settings.speedMode.rawValue, privacy: .public): limit \(limit.map { "\($0) B/s" } ?? "none", privacy: .public)")
        await engine.setGlobalSpeedLimit(limit)
    }

    /// Switches every download to the speed of `mode` (the bar at the bottom of the window, the menu).
    func selectSpeedMode(_ mode: SpeedMode) {
        guard settings.speedMode != mode else { return }
        settings.speedMode = mode
        Task { await applyEngineSettings() }
    }

    // MARK: Events

    /// Why downloads that are waiting are not starting, when some are waiting because of the connection: what the
    /// banner under the toolbar reports. `nil` when nothing waits for it, so a Mac that is simply offline with an empty
    /// list says nothing.
    var networkBanner: NetworkBlock? {
        guard let block = network.block, downloads.values.contains(where: { $0.state == .queued }) else { return nil }
        return block
    }

    /// The download's status as the list shows it: a queued download says why it is not starting when the connection
    /// is the reason.
    func statusText(of download: DownloadSnapshot) -> String {
        download.state == .queued && network.block != nil ? String(localized: "Waiting for network") : download.statusText
    }

    /// "Download Anyway" on the banner: use the expensive or constrained connection until the connection changes.
    func downloadAnyway() {
        Task { await engine.overrideNetworkBlock() }
    }

    /// Applies everything received since the last call. Only the newest event per download matters.
    func flushEvents() {
        let events = inbox.take()
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .snapshot(let snapshot):
                let previous = downloads[snapshot.id]?.state
                downloads[snapshot.id] = snapshot
                if isNewCompletion(snapshot, previous: previous) { onCompleted?(snapshot) }
            case .removed(let id):
                downloads[id] = nil
            }
        }
        refreshCounts()
        recomputeVisible()
    }

    private func isNewCompletion(_ snapshot: DownloadSnapshot, previous: DownloadState?) -> Bool {
        guard snapshot.state == .completed else { return false }
        if let previous { return previous != .completed }
        // First sight of this download. A small file can go from queued to done within one refresh, so this
        // still counts if it finished during this session; downloads restored at launch finished before it.
        return (snapshot.completedAt ?? .distantPast) >= startedAt
    }

    private func recomputeVisible() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = downloads.values.filter { download in
            sidebarSelection.includes(download)
                && (query.isEmpty
                    || download.displayName.localizedCaseInsensitiveContains(query)
                    || download.url.absoluteString.localizedCaseInsensitiveContains(query))
        }
        // The tiebreakers keep equal rows in a stable order between refreshes. A batch added together can share a
        // `createdAt` (job files keep milliseconds), so the order they were added in comes before the id.
        let tiebreakers = [
            KeyPathComparator(\DownloadSnapshot.createdAt, order: .reverse),
            KeyPathComparator(\DownloadSnapshot.sequence, order: .reverse),
            KeyPathComparator(\DownloadSnapshot.id.uuidString),
        ]
        visibleDownloads = filtered.sorted(using: sortOrder + tiebreakers)

        let visibleIDs = Set(visibleDownloads.map(\.id))
        if !selection.isSubset(of: visibleIDs) { selection.formIntersection(visibleIDs) }

        let positions = downloads.values.filter { $0.state != .completed }.sorted { $0.queueOrder < $1.queueOrder }
            .enumerated().reduce(into: [DownloadID: Int]()) { $0[$1.element.id] = $1.offset + 1 }
        if positions != queuePositions { queuePositions = positions }
    }

    // MARK: Derived state

    /// How many downloads each sidebar row shows. Computed once per refresh; the sidebar only redraws when a
    /// count actually changes, not on every progress tick.
    private(set) var counts: [SidebarItem: Int] = [:]

    func count(for item: SidebarItem) -> Int { counts[item] ?? 0 }

    private func refreshCounts() {
        var fresh = Dictionary(uniqueKeysWithValues: (SidebarItem.downloadItems + SidebarItem.categoryItems).map { ($0, 0) })
        for download in downloads.values {
            for item in SidebarItem.downloadItems where item.includes(download) { fresh[item, default: 0] += 1 }
            // A download is in exactly one category; classifying it once (not once per category row) matters when many
            // downloads still have no file name and it is worked out from the address.
            fresh[.category(download.category), default: 0] += 1
        }
        if fresh != counts { counts = fresh }
    }

    var selectedDownloads: [DownloadSnapshot] { ordered(selection) }

    /// The single selected download, for the inspector.
    var inspectedDownload: DownloadSnapshot? {
        let selected = selectedDownloads
        return selected.count == 1 ? selected.first : nil
    }

    var canPauseSelection: Bool { selectedDownloads.contains { $0.isPausable } }
    var canResumeSelection: Bool { selectedDownloads.contains { $0.isResumable } }
    var canRevealSelection: Bool { !selectedDownloads.isEmpty }

    var totalBytesPerSecond: Double { downloads.values.reduce(0) { $0 + $1.bytesPerSecond } }
    var runningCount: Int { downloads.values.filter { $0.state.isRunning }.count }

    // MARK: Actions on downloads

    func pauseSelection() { pause(selection) }
    func resumeSelection() { resume(selection) }

    func pause(_ ids: Set<DownloadID>) {
        let targets = ordered(ids).filter(\.isPausable).map(\.id)
        Task { for id in targets { await engine.pause(id) } }
    }

    /// Resumes paused downloads and retries failed ones.
    func resume(_ ids: Set<DownloadID>) {
        let targets = ordered(ids).filter(\.isResumable).map(\.id)
        Task { for id in targets { await engine.resume(id) } }
    }

    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }

    /// Removes downloads from the list, asking first when that would delete partly downloaded data. With
    /// `trashFiles`, finished files also go to the Trash; otherwise they are kept.
    func requestRemoval(_ ids: Set<DownloadID>, trashFiles: Bool = false) {
        let targets = ordered(ids)
        guard !targets.isEmpty else { return }
        let partial = targets.filter { $0.state != .completed && $0.receivedBytes > 0 }
        // Asking is for what cannot be undone: partly downloaded data, and a whole batch of entries at once
        // (Select All, then Delete, would otherwise empty the list in one keystroke).
        if partial.isEmpty && targets.count == 1 {
            performRemoval(of: targets, trashFiles: trashFiles)
        } else {
            pendingRemoval = PendingRemoval(ids: Set(targets.map(\.id)), trashFiles: trashFiles, partialCount: partial.count, totalCount: targets.count)
        }
    }

    func confirmRemoval() {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        performRemoval(of: ordered(pending.ids), trashFiles: pending.trashFiles)
    }

    func cancelRemoval() { pendingRemoval = nil }

    private func performRemoval(of targets: [DownloadSnapshot], trashFiles: Bool) {
        Task {
            for target in targets {
                if trashFiles, let file = target.completedFileURL {
                    do {
                        try trash(file)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        // Already gone: nothing to trash, the entry can still go.
                    } catch {
                        alert = AlertMessage(title: String(localized: "Couldn’t Move “\(target.displayName)” to the Trash"), message: error.localizedDescription)
                        continue
                    }
                }
                await engine.remove(target.id, deleteFiles: false)
            }
        }
    }

    // MARK: Queue

    /// Whether the list is sorted by the queue, top to bottom. Only then can rows be dragged to reorder: in any other
    /// sort, where a row is dropped says nothing about where it goes in the queue.
    var isQueueOrdered: Bool {
        guard let first = sortOrder.first else { return false }
        return first.keyPath == \DownloadSnapshot.queueSortKey as PartialKeyPath<DownloadSnapshot> && first.order == .forward
    }

    /// The downloads among `ids` that still have a place in the queue (not finished), in on-screen order.
    private func queueable(_ ids: Set<DownloadID>) -> [DownloadID] {
        ordered(ids).filter { $0.state != .completed }.map(\.id)
    }

    var canReorderSelection: Bool { !queueable(selection).isEmpty }

    /// The one priority all of `ids` have, or `nil` when they differ (or none has a place in the queue).
    func priority(of ids: Set<DownloadID>) -> DownloadPriority? {
        let priorities = Set(ordered(ids).filter { $0.state != .completed }.map(\.priority))
        return priorities.count == 1 ? priorities.first : nil
    }

    func moveToTop(_ ids: Set<DownloadID>) {
        let list = queueable(ids)
        guard !list.isEmpty else { return }
        Task { await engine.moveToTop(list) }
    }

    func moveToBottom(_ ids: Set<DownloadID>) {
        let list = queueable(ids)
        guard !list.isEmpty else { return }
        Task { await engine.moveToBottom(list) }
    }

    func setPriority(_ priority: DownloadPriority, for ids: Set<DownloadID>) {
        let list = queueable(ids)
        guard !list.isEmpty else { return }
        Task { await engine.setPriority(priority, for: list) }
    }

    /// Rows were dropped between two rows of the list: put those downloads in front of the download now at `row` (at the
    /// end of the queue when the drop is after the last row).
    func dropInQueue(_ providers: [NSItemProvider], atRow row: Int) {
        guard isQueueOrdered else { return }
        // Worked out now: the list can change while the providers are read.
        let target = visibleDownloads.indices.contains(row) ? visibleDownloads[row].id : nil
        Task {
            var ids: [DownloadID] = []
            for provider in providers {
                if let id = await QueueDrag.id(from: provider) { ids.append(id) }
            }
            guard !ids.isEmpty else { return }
            await engine.move(ids, before: target)
        }
    }

    /// The visible downloads among `ids`, in on-screen order.
    private func ordered(_ ids: Set<DownloadID>) -> [DownloadSnapshot] {
        visibleDownloads.filter { ids.contains($0.id) }
    }

    func revealInFinder(_ ids: Set<DownloadID>) {
        let urls = ordered(ids).map { download -> URL in
            if let final = download.finalURL { return final }
            if let name = download.filename {
                let part = download.destinationDirectory.appending(path: name + ".part", directoryHint: .notDirectory)
                if FileManager.default.fileExists(atPath: part.path) { return part }
            }
            return download.destinationDirectory
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ download: DownloadSnapshot) {
        guard let url = download.completedFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Files

    /// The finished file of a download, when it is (still) there. Only a real file can be dragged out or previewed: a
    /// running download has just a `.part` file, and a finished one may have been moved or deleted since.
    func availableFile(of download: DownloadSnapshot) -> URL? {
        guard let url = download.completedFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// What dragging a row out of the list hands to Finder or any other app, or nil when there is no file to hand over.
    /// It is the file's address (`NSItemProvider(contentsOf:)` would instead promise the file's contents and make the
    /// receiver read a copy). Whichever is used, SwiftUI clones the file into `~/Library/Caches/com.apple.SwiftUI.Drag-*`
    /// for the receiver to read: instant and free on APFS, but the clone is left behind afterwards.
    func dragProvider(for download: DownloadSnapshot) -> NSItemProvider? {
        // A download that is not finished has no file to hand over: dragging it reorders the queue (when the list is
        // in queue order, so that where it is dropped means something).
        if download.state != .completed { return isQueueOrdered ? QueueDrag.provider(for: download.id) : nil }
        return availableFile(of: download).map { url in
            let provider = NSItemProvider(object: url as NSURL)
            // Only this process sees the mark, so the window can refuse the drag when it is dropped back on it.
            provider.registerDataRepresentation(forTypeIdentifier: OwnDrag.identifier, visibility: .ownProcess) { completion in
                completion(Data(), nil)
                return nil
            }
            return provider
        }
    }

    /// What Quick Look shows for the selection: the selected finished files, in on-screen order.
    var quickLookItems: [QuickLookItem] {
        selectedDownloads.compactMap { download in
            availableFile(of: download).map { QuickLookItem(id: download.id, url: $0, title: download.displayName) }
        }
    }

    /// Whether the Quick Look command can do anything. Cheap, so a menu can ask on every refresh: it does not look at
    /// the disk the way `quickLookItems` does.
    var canQuickLookSelection: Bool { selectedDownloads.contains { $0.completedFileURL != nil } }

    /// Makes `ids` the selection unless they are already part of it.
    func selectIfNeeded(_ ids: Set<DownloadID>) {
        guard !ids.isSubset(of: selection) else { return }
        let visible = Set(visibleDownloads.map(\.id))
        selection = ids.intersection(visible)
    }

    /// The row a download has in the list on screen.
    func row(of id: DownloadID) -> Int? { visibleDownloads.firstIndex { $0.id == id } }

    /// Moves a single selection up or down the list, as the arrow keys do, and stops at either end.
    func moveSelection(by offset: Int) {
        guard selection.count == 1, let only = selection.first, let index = row(of: only) else { return }
        let target = min(max(index + offset, 0), visibleDownloads.count - 1)
        selection = [visibleDownloads[target].id]
    }

    func copyLinks(_ ids: Set<DownloadID>) {
        let text = ordered(ids).map(\.url.absoluteString).joined(separator: "\n")
        guard !text.isEmpty else { return }
        lastSeenClipboardChange = pasteboard.copy(text) // our own copy is not an offer
    }

    // MARK: Adding

    /// Adds every request; a link the engine refuses does not stop the rest.
    func add(_ requests: [NewDownload]) async -> AddOutcome {
        var outcome = AddOutcome()
        log.info("Adding \(requests.count, privacy: .public) download(s)")
        for request in requests {
            do {
                try await engine.add(request)
                outcome.added += 1
            } catch {
                outcome.failedLinks.append(request.url)
                // Never the password of a `user:pass@` link: this text is shown, and can be selected and copied.
                outcome.failures.append("\(request.url.withoutCredentials.absoluteString): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Opens the Add sheet with `links` filled in. If the sheet is already open, they are appended.
    func presentAddSheet(links: [URL] = []) {
        log.info("Showing the Add sheet with \(links.count, privacy: .public) link(s); nothing is added until confirmed")
        if showAddSheet {
            // Links from outside join the ones the user is looking at, but do not get the cookies and login they typed.
            draft.append(links, fromOutside: true)
        } else {
            resetDraft()
            draft.append(links)
            showAddSheet = true
        }
    }

    /// Forgets everything typed into the Add sheet, passwords and cookies included. Called when the sheet closes,
    /// so secrets do not linger in memory.
    func resetDraft() {
        sheetNote = nil
        draft = AddDraft(folder: settings.downloadFolder, segmentCount: settings.segmentCount, userAgent: settings.defaultUserAgent)
    }

    /// Anything the system hands the app: `fetchthings://` links, dropped or opened text files, and
    /// plain web links. All of it only *proposes* downloads in the Add sheet.
    func handleIncoming(urls: [URL]) {
        Task {
            let resolution = await IncomingLinks.resolve(urls)
            log.info("Received \(urls.count, privacy: .public) item(s) from the system, \(resolution.links.count, privacy: .public) link(s) found")
            if !resolution.links.isEmpty { presentAddSheet(links: resolution.links) }
            if let problem = resolution.problems.first {
                report(title: resolution.links.isEmpty ? String(localized: "No Links Found") : String(localized: "Some Items Were Skipped"), message: problem)
            } else if resolution.links.isEmpty {
                report(title: String(localized: "No Links Found"), message: String(localized: "There were no http or https links in what you opened or dropped."))
            }
        }
    }

    /// Pasted or dropped text.
    func handleText(_ text: String) {
        let links = LinkParser.urls(in: text)
        if links.isEmpty {
            report(title: String(localized: "No Links Found"), message: String(localized: "The text doesn’t contain an http or https link."))
        } else {
            presentAddSheet(links: links)
        }
    }

    /// Tells the user that what they dropped or pasted held nothing to add. While the Add sheet is up an alert would sit
    /// on the window behind it and only appear once the sheet closes, so the sheet shows the remark itself.
    private func report(title: String, message: String) {
        if showAddSheet {
            sheetNote = message
        } else {
            alert = AlertMessage(title: title, message: message)
        }
    }

    func addFromClipboard() {
        Task {
            let links = await pasteboard.links()
            if links.isEmpty {
                report(title: String(localized: "No Links on the Clipboard"), message: String(localized: "Copy an http or https link first."))
            } else {
                presentAddSheet(links: links)
            }
        }
    }

    // MARK: Clipboard

    func checkClipboard() async {
        guard settings.detectClipboard, isAppActive(), !showAddSheet else { return }
        let change = pasteboard.changeCount
        guard change != lastSeenClipboardChange else { return }
        lastSeenClipboardChange = change
        let known = Set(downloads.values.map(\.url.absoluteString))
        let links = await pasteboard.links().filter { !known.contains($0.absoluteString) }
        clipboardOffer = links.isEmpty ? nil : links
    }

    func acceptClipboardOffer() {
        guard let links = clipboardOffer else { return }
        clipboardOffer = nil
        presentAddSheet(links: links)
    }

    func dismissClipboardOffer() {
        clipboardOffer = nil
    }
}

/// A finished file that Quick Look can show.
struct QuickLookItem: Equatable {
    let id: DownloadID
    let url: URL
    let title: String
}
