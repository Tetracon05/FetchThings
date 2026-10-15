import DownloadKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FetchThings

@MainActor
@Suite("AppModel", .serialized)
struct AppModelTests {
    /// Starts the model and waits for `count` downloads to have arrived.
    private func started(_ count: Int, _ snapshots: [DownloadSnapshot], _ ctx: (model: AppModel, engine: FakeEngine, pasteboard: FakePasteboard, settings: AppSettings)) async -> Bool {
        ctx.model.start()
        // Give the model's consumer a moment to subscribe before sending.
        _ = await eventually { await ctx.engine.calls.contains("load") }
        try? await Task.sleep(for: .milliseconds(30))
        for s in snapshots { await ctx.engine.send(.snapshot(s)) }
        return await eventually { ctx.model.flushEvents(); return ctx.model.downloads.count == count }
    }

    // MARK: Events

    @Test func loadsThenAppliesSettingsThenFollowsEvents() async {
        let ctx = makeModel { $0.maxConcurrentDownloads = 4; $0.speedMode = .low; $0.lowLimitKBps = 500 }
        #expect(await started(2, [snapshot("a.zip"), snapshot("b.zip")], ctx))
        let calls = await ctx.engine.calls
        // Limits go in before anything is loaded: restored downloads start the moment they are loaded.
        #expect(calls.prefix(3) == ["maxConcurrent 4", "globalLimit 500000", "load"])
        #expect(ctx.model.visibleDownloads.count == 2)
        await ctx.model.shutdown()
    }

    @Test func onlyTheNewestEventPerDownloadIsApplied() async {
        let ctx = makeModel()
        var item = snapshot("a.zip", state: .downloading, total: 1000, received: 0)
        ctx.model.start()
        _ = await eventually { await ctx.engine.calls.contains("load") }
        try? await Task.sleep(for: .milliseconds(30))
        for received in stride(from: 0, through: 900, by: 10) {
            item.receivedBytes = Int64(received)
            await ctx.engine.send(.snapshot(item))
        }
        #expect(await eventually { ctx.model.flushEvents(); return ctx.model.downloads[item.id]?.receivedBytes == 900 })
        await ctx.model.shutdown()
    }

    @Test func removalDropsTheRowAndTheSelection() async {
        let ctx = makeModel()
        let a = snapshot("a.zip"), b = snapshot("b.zip")
        #expect(await started(2, [a, b], ctx))
        ctx.model.selection = [a.id, b.id]
        await ctx.engine.send(.removed(a.id))
        #expect(await eventually { ctx.model.flushEvents(); return ctx.model.downloads.count == 1 })
        #expect(ctx.model.selection == [b.id])
        await ctx.model.shutdown()
    }

    @Test func completionIsAnnouncedOnceAndNotForRestoredDownloads() async {
        let ctx = makeModel()
        var completed: [String] = []
        ctx.model.onCompleted = { completed.append($0.displayName) }
        var running = snapshot("live.zip", state: .downloading)
        let restored = snapshot("old.zip", state: .completed)
        #expect(await started(2, [running, restored], ctx))
        #expect(completed.isEmpty, "a download that was already finished when the app opened is not news")

        running.state = .completed
        await ctx.engine.send(.snapshot(running))
        _ = await eventually { ctx.model.flushEvents(); return !completed.isEmpty }
        await ctx.engine.send(.snapshot(running)) // a repeat must not announce again
        try? await Task.sleep(for: .milliseconds(300)); ctx.model.flushEvents()
        #expect(completed == ["live.zip"])
        await ctx.model.shutdown()
    }

    @Test func aggregatesForTheMenuBarAndSubtitle() async {
        let ctx = makeModel()
        #expect(await started(3, [snapshot("a", state: .downloading, speed: 1000), snapshot("b", state: .downloading, speed: 500), snapshot("c", state: .paused, speed: 0)], ctx))
        #expect(ctx.model.totalBytesPerSecond == 1500)
        #expect(ctx.model.runningCount == 2)
        await ctx.model.shutdown()
    }

    // MARK: Filtering, search, sorting

    @Test func sidebarFilterSearchAndCounts() async {
        let ctx = makeModel()
        let all = [
            snapshot("movie.mp4", url: "https://a.com/movie.mp4", state: .downloading),
            snapshot("song.mp3", url: "https://b.com/song.mp3", state: .completed),
            snapshot("app.dmg", url: "https://c.com/app.dmg", state: .failed),
            snapshot("notes.pdf", url: "https://d.com/notes.pdf", state: .paused),
        ]
        #expect(await started(4, all, ctx))

        #expect(ctx.model.count(for: .all) == 4)
        #expect(ctx.model.count(for: .active) == 2)
        #expect(ctx.model.count(for: .completed) == 1)
        #expect(ctx.model.count(for: .failed) == 1)
        #expect(ctx.model.count(for: .category(.audio)) == 1)

        ctx.model.sidebarSelection = .completed
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["song.mp3"])
        ctx.model.sidebarSelection = .all
        ctx.model.searchText = "  NOTES "
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["notes.pdf"])
        ctx.model.searchText = "c.com"
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["app.dmg"], "search also matches the address")
        ctx.model.searchText = "nothing matches this"
        #expect(ctx.model.visibleDownloads.isEmpty)
        await ctx.model.shutdown()
    }

    @Test func sortingByColumnAndTheDefaultOrder() async {
        let ctx = makeModel()
        let all = [
            snapshot("b.zip", total: 300, created: 10),
            snapshot("a.zip", total: 100, created: 30),
            snapshot("c.zip", total: nil, created: 20),
        ]
        #expect(await started(3, all, ctx))
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["a.zip", "c.zip", "b.zip"], "newest first by default")

        ctx.model.sortOrder = [KeyPathComparator(\DownloadSnapshot.displayName)]
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["a.zip", "b.zip", "c.zip"])
        ctx.model.sortOrder = [KeyPathComparator(\DownloadSnapshot.sizeSortKey, order: .reverse)]
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["b.zip", "a.zip", "c.zip"])
        await ctx.model.shutdown()
    }

    @Test func equalRowsKeepAStableOrder() async {
        let ctx = makeModel()
        let all = (0..<6).map { _ in snapshot("same.zip", created: 5) }
        #expect(await started(6, all, ctx))
        let first = ctx.model.visibleDownloads.map(\.id)
        ctx.model.sortOrder = [KeyPathComparator(\DownloadSnapshot.displayName)]
        #expect(ctx.model.visibleDownloads.map(\.id) == first)
        await ctx.model.shutdown()
    }

    // MARK: Selection

    @Test func detailsPaneIsHiddenUntilTheUserOpensIt() {
        #expect(makeModel().model.showInspector == false)
    }

    @Test func inspectorShowsOnlyASingleSelection() async {
        let ctx = makeModel()
        let a = snapshot("a.zip"), b = snapshot("b.zip")
        #expect(await started(2, [a, b], ctx))
        #expect(ctx.model.inspectedDownload == nil)
        ctx.model.selection = [a.id]
        #expect(ctx.model.inspectedDownload?.id == a.id)
        ctx.model.selection = [a.id, b.id]
        #expect(ctx.model.inspectedDownload == nil)
        await ctx.model.shutdown()
    }

    @Test func toolbarStateFollowsTheSelection() async {
        let ctx = makeModel()
        let running = snapshot("r", state: .downloading), paused = snapshot("p", state: .paused), done = snapshot("d", state: .completed)
        #expect(await started(3, [running, paused, done], ctx))
        #expect(!ctx.model.canPauseSelection && !ctx.model.canResumeSelection && !ctx.model.canRevealSelection)
        ctx.model.selection = [running.id]
        #expect(ctx.model.canPauseSelection && !ctx.model.canResumeSelection && ctx.model.canRevealSelection)
        ctx.model.selection = [paused.id]
        #expect(!ctx.model.canPauseSelection && ctx.model.canResumeSelection)
        ctx.model.selection = [done.id]
        #expect(!ctx.model.canPauseSelection && !ctx.model.canResumeSelection && ctx.model.canRevealSelection)
        await ctx.model.shutdown()
    }

    // MARK: Files

    /// A folder with a real file per name, removed by the caller.
    private func folder(with names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppModelFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    @Test func onlyAFinishedFileThatIsStillThereCanBeDraggedOrPreviewed() async throws {
        let dir = try folder(with: ["done.mov"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeModel()
        let done = snapshot("done.mov", state: .completed, finalURL: dir.appendingPathComponent("done.mov"))
        let running = snapshot("run.mov", state: .downloading, finalURL: nil)
        let moved = snapshot("moved.mov", state: .completed, finalURL: dir.appendingPathComponent("moved.mov"))
        // Not finished, but with a file name on disk already: still nothing to hand over.
        let unfinished = snapshot("done.mov", state: .paused, finalURL: dir.appendingPathComponent("done.mov"))
        #expect(await started(4, [done, running, moved, unfinished], ctx))

        let model = ctx.model
        #expect(model.availableFile(of: done) == dir.appendingPathComponent("done.mov"))
        #expect(model.availableFile(of: running) == nil)
        #expect(model.availableFile(of: moved) == nil)
        #expect(model.availableFile(of: unfinished) == nil)

        // The drag carries the file itself, as a file URL (what Finder and other apps accept).
        let provider = try #require(model.dragProvider(for: done))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        // A download that is not finished has no file to hand over, so it cannot be dragged at all.
        #expect(model.dragProvider(for: running) == nil)
        #expect(model.dragProvider(for: moved) == nil, "a finished file that is gone has nothing to drag")
        await model.shutdown()
    }

    @Test func aFinishedDownloadWhoseFileIsGoneIsFlaggedMissing() async throws {
        let dir = try folder(with: ["here.zip"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeModel()
        let here = snapshot("here.zip", state: .completed, finalURL: dir.appendingPathComponent("here.zip"))
        let gone = snapshot("gone.zip", state: .completed, finalURL: dir.appendingPathComponent("gone.zip"))
        let running = snapshot("run.zip", state: .downloading)
        #expect(await started(3, [here, gone, running], ctx))
        let model = ctx.model

        #expect(!model.fileIsMissing(here))
        #expect(model.statusText(of: here) == here.statusText)
        #expect(model.fileIsMissing(gone))
        #expect(model.statusText(of: gone) == String(localized: "File Missing"))
        #expect(!model.fileIsMissing(running), "only a finished download can have a missing file")

        // Trying to open it shows an alert instead of handing a dead path to NSWorkspace.
        model.open(gone)
        #expect(model.alert?.message == String(localized: "The file is no longer at this location."))
        await model.shutdown()
    }

    @Test func draggingFromThePaneHandsOverOnlyFilesThatExistInTheOrderGiven() async throws {
        let dir = try folder(with: ["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeModel()
        let a = snapshot("a.png", state: .completed, finalURL: dir.appendingPathComponent("a.png"))
        let b = snapshot("b.png", state: .completed, finalURL: dir.appendingPathComponent("b.png"))
        let running = snapshot("r.png", state: .downloading)
        let gone = snapshot("gone.png", state: .completed, finalURL: dir.appendingPathComponent("gone.png"))
        #expect(await started(4, [a, b, running, gone], ctx))

        // What a drag out of the details pane carries: the finished files that are still there, in the order given.
        let box = CGSize(width: 10, height: 10)
        func dragged(_ downloads: [DownloadSnapshot]) -> [URL] { FileDragSource.items(for: downloads, in: ctx.model, box: box).map(\.url) }
        #expect(dragged([b, running, gone, a]) == [dir.appendingPathComponent("b.png"), dir.appendingPathComponent("a.png")])
        #expect(dragged([running, gone]).isEmpty)
        #expect(dragged([]).isEmpty)
        await ctx.model.shutdown()
    }

    @Test func everyDragOutOfTheAppCarriesTheMarkThatLetsTheWindowRefuseIt() async throws {
        let dir = try folder(with: ["a.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeModel()
        let file = dir.appendingPathComponent("a.png")
        let a = snapshot("a.png", state: .completed, finalURL: file)
        #expect(await started(1, [a], ctx))

        // A row dragged out of the list.
        let provider = try #require(ctx.model.dragProvider(for: a))
        #expect(provider.hasItemConformingToTypeIdentifier(OwnDrag.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        // The picture or pile dragged out of the details pane.
        let item = DragSourceView.pasteboardItem(for: file)
        #expect(item.types.contains(OwnDrag.pasteboardType))
        #expect(item.string(forType: .fileURL) == file.absoluteString)
        await ctx.model.shutdown()
    }

    @Test func quickLookShowsTheSelectedFinishedFilesInListOrder() async throws {
        let dir = try folder(with: ["a.png", "b.png", "c.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = makeModel()
        let a = snapshot("a.png", state: .completed, created: 3, finalURL: dir.appendingPathComponent("a.png"))
        let b = snapshot("b.png", state: .completed, created: 2, finalURL: dir.appendingPathComponent("b.png"))
        let c = snapshot("c.png", state: .completed, created: 1, finalURL: dir.appendingPathComponent("c.png"))
        let running = snapshot("r.png", state: .downloading, created: 0)
        #expect(await started(4, [a, b, c, running], ctx))
        let model = ctx.model

        #expect(model.quickLookItems.isEmpty) // nothing selected
        #expect(!model.canQuickLookSelection)
        model.selection = [running.id]
        #expect(model.quickLookItems.isEmpty) // nothing to show yet
        #expect(!model.canQuickLookSelection)
        model.selection = Set([a, b, c, running].map(\.id))
        // The running one is left out; the rest come in the order the list shows them.
        #expect(model.quickLookItems.map(\.title) == model.visibleDownloads.filter { $0.state == .completed }.map(\.displayName))
        #expect(model.quickLookItems.count == 3)
        model.selection = [b.id]
        #expect(model.canQuickLookSelection)
        #expect(model.quickLookItems.map(\.url) == [dir.appendingPathComponent("b.png")])
        await model.shutdown()
    }

    @Test func theArrowKeysMoveASingleSelectionAndStopAtTheEnds() async {
        let ctx = makeModel()
        let a = snapshot("a", created: 3), b = snapshot("b", created: 2), c = snapshot("c", created: 1)
        #expect(await started(3, [a, b, c], ctx))
        let model = ctx.model
        let order = model.visibleDownloads.map(\.id)

        model.moveSelection(by: 1)
        #expect(model.selection.isEmpty) // nothing selected: nothing to move
        model.selection = [order[0]]
        model.moveSelection(by: -1)
        #expect(model.selection == [order[0]]) // at the top already
        model.moveSelection(by: 1)
        #expect(model.selection == [order[1]])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selection == [order[2]]) // stops at the bottom
        model.selection = [order[0], order[1]]
        model.moveSelection(by: 1)
        #expect(model.selection == [order[0], order[1]]) // several selected: left alone
        await model.shutdown()
    }

    @Test func aRightClickedRowThatIsNotSelectedBecomesTheSelection() async {
        let ctx = makeModel()
        let a = snapshot("a", created: 3), b = snapshot("b", created: 2), c = snapshot("c", created: 1)
        #expect(await started(3, [a, b, c], ctx))
        let model = ctx.model
        let order = model.visibleDownloads.map(\.id)

        model.selection = [order[0]]
        model.selectIfNeeded([order[2]])
        #expect(model.selection == [order[2]], "Quick Look from a menu on another row must preview that row")

        model.selection = [order[0], order[1]]
        model.selectIfNeeded([order[1]])
        #expect(model.selection == [order[0], order[1]], "a row inside the selection leaves it as it is")
        model.selectIfNeeded([UUID()])
        #expect(model.selection.isSubset(of: Set(order)), "an id that is not in the list never joins the selection")
        await model.shutdown()
    }

    @Test func aBatchAddedTogetherKeepsItsOrderEvenWhenItsTimesTie() async {
        let ctx = makeModel()
        // Job files keep milliseconds, so a batch can share a createdAt; the order they were added in decides.
        let first = snapshot("first", created: 5, sequence: 1), second = snapshot("second", created: 5, sequence: 2), third = snapshot("third", created: 5, sequence: 3)
        #expect(await started(3, [second, first, third], ctx))
        ctx.model.sortOrder = [KeyPathComparator(\.createdAt, order: .reverse)] // by date added, newest first
        #expect(ctx.model.visibleDownloads.map(\.sequence) == [3, 2, 1], "newest first, like createdAt")
        await ctx.model.shutdown()
    }

    @Test func theListIsSortedByDateAddedNewestFirstByDefault() async {
        let ctx = makeModel()
        let a = snapshot("a", created: 1, sequence: 1), b = snapshot("b", created: 2, sequence: 2), c = snapshot("c", created: 3, sequence: 3)
        #expect(await started(3, [a, b, c], ctx))
        #expect(ctx.model.visibleDownloads.map(\.displayName) == ["c", "b", "a"])
        await ctx.model.shutdown()
    }

    // MARK: Priority

    @Test func settingPriorityAsksTheEngineOnlyAboutDownloadsThatAreNotFinished() async {
        let ctx = makeModel()
        let a = snapshot("a", sequence: 1), done = snapshot("done", state: .completed, sequence: 2, completedAt: 5), b = snapshot("b", sequence: 3)
        #expect(await started(3, [a, done, b], ctx))
        let model = ctx.model
        model.selection = [done.id]
        #expect(!model.canChangePrioritySelection)
        model.setPriority(.high, for: model.selection)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await ctx.engine.queueCalls.isEmpty, "a finished download's priority cannot be changed")

        model.selection = [done.id, b.id, a.id]
        #expect(model.canChangePrioritySelection)
        model.setPriority(.low, for: model.selection)
        #expect(await eventually { await ctx.engine.queueCalls.count == 1 })
        #expect(await ctx.engine.queueCalls == ["priority -1 2"])
        await model.shutdown()
    }

    @Test func theMenuShowsThePriorityThatAllTheSelectedShare() async {
        let ctx = makeModel()
        let a = snapshot("a", sequence: 1, priority: .high), b = snapshot("b", sequence: 2, priority: .high), c = snapshot("c", sequence: 3)
        #expect(await started(3, [a, b, c], ctx))
        #expect(ctx.model.priority(of: [a.id, b.id]) == .high)
        #expect(ctx.model.priority(of: [a.id, c.id]) == nil, "different: no check mark")
        #expect(ctx.model.priority(of: []) == nil)
        await ctx.model.shutdown()
    }

    // MARK: The network

    @Test func theModelFollowsTheNetworkAndQueuedDownloadsSayWhyTheyWait() async {
        let ctx = makeModel()
        let queued = snapshot("a.zip", state: .queued), running = snapshot("b.zip", state: .downloading)
        #expect(await started(2, [queued, running], ctx))
        #expect(ctx.model.networkBanner == nil && ctx.model.statusText(of: queued) == queued.statusText, "nothing waits for the network yet")

        await ctx.engine.sendNetwork(NetworkState(status: .offline, block: .offline))
        #expect(await eventually { ctx.model.network.block == .offline })
        #expect(ctx.model.networkBanner == .offline)
        #expect(ctx.model.statusText(of: queued) == String(localized: "Waiting for network"))
        #expect(ctx.model.statusText(of: running) == running.statusText, "only a download that waits says so")

        await ctx.engine.sendNetwork(.unrestricted)
        #expect(await eventually { ctx.model.network.block == nil })
        #expect(ctx.model.networkBanner == nil && ctx.model.statusText(of: queued) == queued.statusText)
        await ctx.model.shutdown()
    }

    @Test func theBannerIsOnlyShownWhileSomethingWaitsForTheConnection() async {
        let ctx = makeModel()
        #expect(await started(1, [snapshot("b.zip", state: .downloading)], ctx))
        await ctx.engine.sendNetwork(NetworkState(status: .offline, block: .offline))
        #expect(await eventually { ctx.model.network.block == .offline })
        #expect(ctx.model.networkBanner == nil, "an offline Mac with nothing queued has nothing to report")
        await ctx.model.shutdown()
    }

    @Test func downloadAnywayTellsTheEngine() async {
        let ctx = makeModel()
        ctx.model.downloadAnyway()
        #expect(await eventually { await ctx.engine.networkOverrides == 1 })
    }

    @Test func theNetworkPolicyReachesTheEngineBeforeAnythingIsLoaded() async {
        let ctx = makeModel { $0.pauseOnExpensiveNetwork = true; $0.pauseOnConstrainedNetwork = false }
        #expect(await started(0, [], ctx))
        #expect(await ctx.engine.policySetBeforeLoad, "restored downloads start the moment they are loaded")
        #expect(await ctx.engine.networkPolicies.first == NetworkPolicy(pauseOnExpensive: true, pauseOnConstrained: false))
        await ctx.model.shutdown()
    }

    @Test func everyFilterHasItsOwnWholeSentenceForWhenItIsEmpty() {
        let messages = SidebarItem.downloadItems.map(\.emptyMessage) + SidebarItem.categoryItems.map(\.emptyMessage)
        #expect(Set(messages).count == messages.count && !messages.contains(""))
        #expect(SidebarItem.category(.applications).emptyMessage.contains(FileCategory.applications.title), "a category is named in it")
    }

    // MARK: Actions

    @Test func pauseResumeAndRetryOnlyTouchWhatTheyApplyTo() async {
        let ctx = makeModel()
        let running = snapshot("r", state: .downloading), paused = snapshot("p", state: .paused)
        let failed = snapshot("f", state: .failed), done = snapshot("d", state: .completed)
        #expect(await started(4, [running, paused, failed, done], ctx))
        let everything = Set([running.id, paused.id, failed.id, done.id])

        ctx.model.pause(everything)
        #expect(await eventually { await ctx.engine.calls.filter { $0.hasPrefix("pause ") }.count == 1 })
        ctx.model.resume(everything)
        #expect(await eventually { await ctx.engine.calls.filter { $0.hasPrefix("resume ") }.count == 2 })

        let calls = await ctx.engine.calls
        #expect(calls.contains("pause \(running.id)"))
        #expect(calls.contains("resume \(paused.id)") && calls.contains("resume \(failed.id)"), "failed downloads are retried by resuming")
        #expect(!calls.contains("resume \(done.id)") && !calls.contains("pause \(done.id)"))

        ctx.model.pauseAll(); ctx.model.resumeAll()
        #expect(await eventually { let c = await ctx.engine.calls; return c.contains("pauseAll") && c.contains("resumeAll") })
        await ctx.model.shutdown()
    }

    @Test func copyingLinksIsNotMistakenForAClipboardOffer() async {
        let ctx = makeModel { $0.detectClipboard = true }
        ctx.model.isAppActive = { true }
        let a = snapshot("a.zip", url: "https://example.com/a.zip")
        #expect(await started(1, [a], ctx))
        ctx.model.copyLinks([a.id])
        #expect(ctx.pasteboard.copied == ["https://example.com/a.zip"])
        ctx.pasteboard.linksOnClipboard = [URL(string: "https://example.com/other.zip")!]
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer == nil, "the app's own copy must not be offered back")
        await ctx.model.shutdown()
    }

    // MARK: Adding

    @Test func addingKeepsGoingPastRefusedLinks() async {
        let ctx = makeModel()
        await ctx.engine.failAdds(forHost: "bad.example")
        let requests = ["https://ok.example/1", "https://bad.example/2", "https://ok.example/3"].map {
            NewDownload(url: URL(string: $0)!, destinationDirectory: URL(filePath: "/tmp/dl"))
        }
        let outcome = await ctx.model.add(requests)
        #expect(outcome.added == 2)
        #expect(outcome.failedLinks.map(\.absoluteString) == ["https://bad.example/2"])
        #expect(outcome.failures.first?.contains("bad.example") == true)
        #expect(await ctx.engine.added.count == 2)
    }

    @Test func theAddSheetOpensWithSettingsAppliedAndAppendsWhenAlreadyOpen() {
        let ctx = makeModel {
            $0.segmentCount = 12
            $0.downloadFolder = URL(filePath: "/tmp/custom", directoryHint: .isDirectory)
            $0.defaultUserAgent = "Agent/9"
        }
        ctx.model.presentAddSheet(links: [URL(string: "https://example.com/a")!])
        #expect(ctx.model.showAddSheet)
        #expect(ctx.model.draft.segmentCount == 12 && ctx.model.draft.folder.path == "/tmp/custom" && ctx.model.draft.userAgent == "Agent/9")
        #expect(ctx.model.draft.links.map(\.absoluteString) == ["https://example.com/a"])

        ctx.model.draft.startPaused = true // the user is mid-edit
        ctx.model.presentAddSheet(links: [URL(string: "https://example.com/b")!])
        #expect(ctx.model.draft.links.map(\.absoluteString) == ["https://example.com/a", "https://example.com/b"])
        #expect(ctx.model.draft.startPaused, "appending must not reset what the user typed")
    }

    @Test func linksThatArriveWhileTheSheetIsOpenDoNotGetTheSheetsSecrets() throws {
        let ctx = makeModel()
        ctx.model.presentAddSheet(links: [URL(string: "https://mine.example/a")!])
        ctx.model.draft.cookies = "session=abc" // typed by the user for their own link
        ctx.model.presentAddSheet(links: [URL(string: "https://evil.example/x")!]) // a fetchthings:// link, say

        let requests = try ctx.model.draft.makeRequests()
        #expect(requests.first { $0.url.host() == "mine.example" }?.sensitive.cookies == "session=abc")
        #expect(requests.first { $0.url.host() == "evil.example" }?.sensitive.isEmpty == true)
    }

    @Test func nothingToAddInADropOnTheOpenSheetIsSaidInTheSheetNotInAnAlertBehindIt() {
        let ctx = makeModel()
        ctx.model.presentAddSheet(links: [URL(string: "https://example.com/a")!])
        ctx.model.handleText("no links in here")
        #expect(ctx.model.sheetNote != nil, "the sheet shows it")
        #expect(ctx.model.alert == nil, "an alert on the window under the sheet would wait until the sheet closed")

        let closed = makeModel()
        closed.model.handleText("no links in here")
        #expect(closed.model.alert != nil && closed.model.sheetNote == nil)
    }

    @Test func aFailedAddNeverShowsTheLinksPassword() async {
        let ctx = makeModel()
        await ctx.engine.failAdds(forHost: "host.example")
        let link = URL(string: "https://alice:hunter2@host.example/f.iso")!
        let outcome = await ctx.model.add([NewDownload(url: link, destinationDirectory: URL(filePath: "/tmp/dl", directoryHint: .isDirectory))])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.contains("hunter2") == false && outcome.failures.first?.contains("alice") == false)
        #expect(outcome.failures.first?.contains("host.example/f.iso") == true, "the link is still named, so the user knows which failed")
        #expect(outcome.failedLinks == [link], "the link kept for a retry is untouched")
    }

    @Test func aFreshSheetStartsFromDefaultsNotFromTheLastOne() {
        let ctx = makeModel()
        ctx.model.presentAddSheet(links: [URL(string: "https://example.com/a")!])
        ctx.model.draft.cookies = "secret=1"
        ctx.model.showAddSheet = false
        ctx.model.presentAddSheet()
        #expect(ctx.model.draft.links.isEmpty && ctx.model.draft.cookies.isEmpty, "cookies from a previous add must not carry over")
    }

    // MARK: Incoming links, files and text

    @Test func aSchemeLinkOnlyFillsInTheSheet() async {
        let ctx = makeModel()
        let link = SchemeLink.addLink(for: [URL(string: "https://example.com/a.zip")!, URL(string: "https://example.com/b.zip")!])
        ctx.model.handleIncoming(urls: [link])
        #expect(await eventually { ctx.model.showAddSheet })
        #expect(ctx.model.draft.links.count == 2)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await ctx.engine.added.isEmpty, "a link from outside must never start a download by itself")
        #expect(!(await ctx.engine.calls.contains { $0.hasPrefix("resume") }))
    }

    @Test func textFilesAreReadAndOthersIgnored() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appending(path: "links.txt")
        try "https://example.com/a.zip\n# skip\nhttps://example.com/b.zip\n".write(to: txt, atomically: true, encoding: .utf8)
        let png = dir.appending(path: "picture.png")
        try "https://example.com/hidden.zip".write(to: png, atomically: true, encoding: .utf8) // not a text file: never read

        let links = await IncomingLinks.resolve([txt, png, URL(string: "https://example.com/a.zip")!, URL(string: "https://example.com/c.zip")!]).links
        #expect(links.map(\.absoluteString) == ["https://example.com/a.zip", "https://example.com/b.zip", "https://example.com/c.zip"], "in order, without duplicates")
    }

    @Test func onlyWebLinksSurviveFromAnyInputEvenALinkThatSmugglesOthers() async {
        let hostile = URL(string: "fetchthings://add?url=file%3A%2F%2F%2Fetc%2Fpasswd&url=ftp%3A%2F%2Fx.example%2Fa&url=javascript%3Aalert(1)&url=https%3A%2F%2Fok.example%2Fa.zip")!
        let links = await IncomingLinks.resolve([hostile, URL(string: "file:///etc/hosts")!, URL(string: "ftp://x.example/a")!, URL(string: "data:text/plain,hi")!]).links
        #expect(links.map(\.absoluteString) == ["https://ok.example/a.zip"])
    }

    @Test func nothingUsableRaisesAnAlertNotASheet() async {
        let ctx = makeModel()
        ctx.model.handleIncoming(urls: [URL(string: "ftp://example.com/x")!, URL(filePath: "/tmp/does-not-exist.txt")])
        #expect(await eventually { ctx.model.alert != nil })
        #expect(ctx.model.alert?.title == String(localized: "No Links Found"))
        #expect(!ctx.model.showAddSheet)
    }

    @Test func pastedAndDroppedTextIsScannedForLinks() {
        let ctx = makeModel()
        ctx.model.handleText("see https://example.com/a.zip please")
        #expect(ctx.model.showAddSheet && ctx.model.draft.links.count == 1)

        let other = makeModel()
        other.model.handleText("no links in here")
        #expect(other.model.alert != nil && !other.model.showAddSheet)
    }

    @Test func addingFromTheClipboardCommand() async {
        let ctx = makeModel()
        ctx.pasteboard.linksOnClipboard = [URL(string: "https://example.com/clip.zip")!]
        ctx.model.addFromClipboard()
        #expect(await eventually { ctx.model.showAddSheet })
        #expect(ctx.model.draft.links.first?.lastPathComponent == "clip.zip")

        let empty = makeModel()
        empty.model.addFromClipboard()
        #expect(await eventually { empty.model.alert?.title == String(localized: "No Links on the Clipboard") })
    }

    // MARK: Clipboard watching

    @Test func clipboardWatchingIsOffUnlessEnabled() async {
        let ctx = makeModel()
        ctx.model.isAppActive = { true }
        ctx.pasteboard.externalCopy([URL(string: "https://example.com/a.zip")!])
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer == nil)
    }

    @Test func clipboardOffersAppearOnceAndOnlyWhileActive() async {
        let ctx = makeModel { $0.detectClipboard = true }
        ctx.model.isAppActive = { false }
        ctx.pasteboard.externalCopy([URL(string: "https://example.com/a.zip")!])
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer == nil, "not while another app is in front")

        // Copy a link in another app, then switch to FetchThings: that is exactly when to offer it.
        ctx.model.isAppActive = { true }
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer?.map(\.lastPathComponent) == ["a.zip"])
        ctx.model.dismissClipboardOffer()

        ctx.pasteboard.externalCopy([URL(string: "https://example.com/b.zip")!])
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer?.map(\.lastPathComponent) == ["b.zip"])

        ctx.model.dismissClipboardOffer()
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer == nil, "an unchanged clipboard is not offered again")
    }

    @Test func linksAlreadyBeingDownloadedAreNotOffered() async {
        let ctx = makeModel { $0.detectClipboard = true }
        ctx.model.isAppActive = { true }
        #expect(await started(1, [snapshot("a.zip", url: "https://example.com/a.zip")], ctx))
        ctx.pasteboard.externalCopy([URL(string: "https://example.com/a.zip")!])
        await ctx.model.checkClipboard()
        #expect(ctx.model.clipboardOffer == nil)
        await ctx.model.shutdown()
    }

    @Test func acceptingAnOfferOpensTheSheetButAddsNothing() async {
        let ctx = makeModel { $0.detectClipboard = true }
        ctx.model.isAppActive = { true }
        ctx.pasteboard.externalCopy([URL(string: "https://example.com/c.zip")!])
        await ctx.model.checkClipboard()
        ctx.model.acceptClipboardOffer()
        #expect(ctx.model.showAddSheet && ctx.model.clipboardOffer == nil)
        #expect(ctx.model.draft.links.count == 1)
        #expect(await ctx.engine.added.isEmpty)
    }

    // MARK: Engine settings

    @Test func settingsAreAppliedToTheEngine() async {
        let ctx = makeModel { $0.maxConcurrentDownloads = 2 }
        await ctx.model.applyEngineSettings()
        ctx.settings.speedMode = .normal
        await ctx.model.applyEngineSettings()
        let calls = await ctx.engine.calls
        #expect(calls == ["maxConcurrent 2", "globalLimit nil", "maxConcurrent 2", "globalLimit 4096000"])
    }

    @Test func pickingASpeedModeLimitsAllDownloadsAtOnce() async {
        let ctx = makeModel()
        ctx.model.selectSpeedMode(.low)
        #expect(ctx.settings.speedMode == .low)
        #expect(await eventually { await ctx.engine.calls.contains("globalLimit 1024000") })

        ctx.model.selectSpeedMode(.normal)
        #expect(await eventually { await ctx.engine.calls.contains("globalLimit 4096000") })

        ctx.model.selectSpeedMode(.high)
        #expect(await eventually { await ctx.engine.calls.last == "globalLimit nil" }, "High removes the limit")

        let before = await ctx.engine.calls.count
        ctx.model.selectSpeedMode(.high) // already High: nothing to tell the engine
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await ctx.engine.calls.count == before)
    }
}

@MainActor
@Suite("Hosting")
struct HostingTests {
    @Test func theTestHostNeverUsesTheRealStorage() {
        #expect(AppEnvironment.isRunningTests, "the app must swap in throwaway storage when it hosts tests")
    }
}
