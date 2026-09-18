import AppKit
import DownloadKit
import Foundation
import Testing
@testable import Downloader

/// One test per defect found in the Phase 2 code review.
@MainActor
@Suite("Phase 2 review regressions", .serialized)
struct Phase2ReviewTests {
    private func started(_ snapshots: [DownloadSnapshot], _ ctx: (model: AppModel, engine: FakeEngine, pasteboard: FakePasteboard, settings: AppSettings)) async -> Bool {
        ctx.model.start()
        _ = await eventually { await ctx.engine.calls.contains("load") }
        try? await Task.sleep(for: .milliseconds(30))
        for s in snapshots { await ctx.engine.send(.snapshot(s)) }
        return await eventually { ctx.model.flushEvents(); return ctx.model.downloads.count == snapshots.count }
    }

    @Test func aSelectionHiddenByTheFilterIsNeverActedOn() async {
        let ctx = makeModel()
        let running = snapshot("a.zip", state: .downloading, total: 1000, received: 900)
        let running2 = snapshot("b.zip", state: .downloading)
        let failed = snapshot("c.zip", state: .failed)
        #expect(await started([running, running2, failed], ctx))

        ctx.model.selection = [running.id, running2.id]
        ctx.model.sidebarSelection = .failed // the selected rows are no longer on screen

        #expect(ctx.model.selection.isEmpty, "rows the user cannot see must not stay selected")
        #expect(!ctx.model.canRevealSelection)
        ctx.model.requestRemoval(ctx.model.selection)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!(await ctx.engine.calls.contains { $0.hasPrefix("remove") }), "a hidden download was removed")
        await ctx.model.shutdown()
    }

    @Test func searchingAlsoDropsHiddenSelections() async {
        let ctx = makeModel()
        let a = snapshot("alpha.zip"), b = snapshot("beta.zip")
        #expect(await started([a, b], ctx))
        ctx.model.selection = [a.id, b.id]
        ctx.model.searchText = "beta"
        #expect(ctx.model.selection == [b.id])
        await ctx.model.shutdown()
    }

    @Test func aDownloadThatFinishesWithinOneRefreshIsStillAnnounced() async {
        let ctx = makeModel()
        var completed: [String] = []
        ctx.model.onCompleted = { completed.append($0.displayName) }
        ctx.model.start()
        _ = await eventually { await ctx.engine.calls.contains("load") }
        try? await Task.sleep(for: .milliseconds(30))

        // A tiny file: queued, downloading and completed all happen before the model's next 200 ms refresh.
        var item = snapshot("tiny.zip", state: .queued)
        await ctx.engine.send(.snapshot(item))
        item.state = .downloading
        await ctx.engine.send(.snapshot(item))
        item.state = .completed
        item.completedAt = Date()
        await ctx.engine.send(.snapshot(item))
        try? await Task.sleep(for: .milliseconds(40))
        ctx.model.flushEvents()

        #expect(completed == ["tiny.zip"], "the completion was coalesced away: \(completed)")
        await ctx.model.shutdown()
    }

    // MARK: Removal

    @Test func removingFinishedOrUntouchedDownloadsNeedsNoConfirmation() async {
        let ctx = makeModel()
        let done = snapshot("d.zip", state: .completed), queued = snapshot("q.zip", state: .queued, total: 1000, received: 0)
        #expect(await started([done, queued], ctx))
        ctx.model.requestRemoval([done.id, queued.id])
        #expect(ctx.model.pendingRemoval == nil)
        #expect(await eventually { await ctx.engine.calls.filter { $0.hasPrefix("remove") }.count == 2 })
        #expect(await ctx.engine.calls.allSatisfy { !$0.contains("deleteFiles=true") }, "finished files are kept by default")
        await ctx.model.shutdown()
    }

    @Test func removingPartialDownloadsAsksFirstAndCancelRemovesNothing() async {
        let ctx = makeModel()
        let partial = snapshot("p.zip", state: .paused, total: 1000, received: 400), done = snapshot("d.zip", state: .completed)
        #expect(await started([partial, done], ctx))

        ctx.model.requestRemoval([partial.id, done.id])
        let pending = try? #require(ctx.model.pendingRemoval)
        #expect(pending?.partialCount == 1 && pending?.totalCount == 2)
        #expect(pending?.message.contains("deleted") == true && pending?.message.contains("kept") == true)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!(await ctx.engine.calls.contains { $0.hasPrefix("remove") }), "nothing happens before the user confirms")

        ctx.model.cancelRemoval()
        #expect(ctx.model.pendingRemoval == nil)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!(await ctx.engine.calls.contains { $0.hasPrefix("remove") }))

        ctx.model.requestRemoval([partial.id])
        ctx.model.confirmRemoval()
        #expect(await eventually { await ctx.engine.calls.contains("remove \(partial.id) deleteFiles=false") })
        #expect(ctx.model.pendingRemoval == nil)
        await ctx.model.shutdown()
    }

    @Test func movingToTheTrashUsesTheTrashNotADelete() async {
        let ctx = makeModel()
        var done = snapshot("d.zip", state: .completed)
        done.finalURL = URL(filePath: "/tmp/dl/d.zip")
        let running = snapshot("r.zip", state: .queued, total: 1000, received: 0)
        #expect(await started([done, running], ctx))
        var trashed: [String] = []
        ctx.model.trash = { trashed.append($0.path) }

        ctx.model.requestRemoval([done.id, running.id], trashFiles: true)
        #expect(await eventually { await ctx.engine.calls.filter { $0.hasPrefix("remove") }.count == 2 })
        #expect(trashed == ["/tmp/dl/d.zip"], "only finished files are trashed")
        #expect(await ctx.engine.calls.allSatisfy { $0.hasSuffix("deleteFiles=false") || !$0.hasPrefix("remove") }, "the engine must not delete permanently")
        await ctx.model.shutdown()
    }

    @Test func aFileThatCannotBeTrashedKeepsItsEntryAndSaysWhy() async {
        let ctx = makeModel()
        var stuck = snapshot("stuck.zip", state: .completed), gone = snapshot("gone.zip", state: .completed)
        stuck.finalURL = URL(filePath: "/tmp/dl/stuck.zip"); gone.finalURL = URL(filePath: "/tmp/dl/gone.zip")
        #expect(await started([stuck, gone], ctx))
        ctx.model.trash = { url in
            throw url.lastPathComponent == "gone.zip" ? CocoaError(.fileNoSuchFile) : CocoaError(.fileWriteNoPermission)
        }
        ctx.model.requestRemoval([stuck.id, gone.id], trashFiles: true)

        #expect(await eventually { ctx.model.alert != nil })
        #expect(ctx.model.alert?.title.contains("stuck.zip") == true)
        #expect(await eventually { await ctx.engine.calls.contains("remove \(gone.id) deleteFiles=false") }, "a file that is already gone does not block removal")
        #expect(!(await ctx.engine.calls.contains("remove \(stuck.id) deleteFiles=false")), "an entry whose file could not be trashed stays")
        await ctx.model.shutdown()
    }

    // MARK: Numbers that used to overflow

    @Test func speedLimitsAreClampedInsteadOfOverflowing() {
        #expect(SpeedLimit.bytesPerSecond(kbps: 0) == nil && SpeedLimit.bytesPerSecond(kbps: -5) == nil)
        #expect(SpeedLimit.bytesPerSecond(kbps: 250) == 250_000)
        #expect(SpeedLimit.bytesPerSecond(kbps: Int.max) == Int64(SpeedLimit.maxKBps) * 1000)
        #expect(SpeedLimit.bytesPerSecond(kbps: Int.min) == nil)
        #expect(SpeedLimit.clamp(20_000_000) == SpeedLimit.maxKBps)
    }

    @Test func hugeStoredOrTypedLimitsDoNotCrashSettingsOrTheDraft() {
        let suite = "DownloaderTests.huge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Int.max, forKey: "speedLimitKBps") // as if a huge number had been persisted
        let settings = AppSettings(defaults: defaults)
        #expect(settings.speedLimitKBps == SpeedLimit.maxKBps)
        #expect(settings.globalSpeedLimit == Int64(SpeedLimit.maxKBps) * 1000)
        settings.speedLimitKBps = Int.max // typed into the field
        #expect(settings.globalSpeedLimit == Int64(SpeedLimit.maxKBps) * 1000)

        var draft = AddDraft(folder: URL(filePath: "/tmp"), segmentCount: 4)
        draft.linksText = "https://example.com/a"
        draft.speedLimitKBps = Int.max
        #expect((try? draft.makeRequests().first?.options.speedLimit) == Int64(SpeedLimit.maxKBps) * 1000)
    }

    // MARK: Add sheet draft

    @Test func theParsedLinksFollowTheText() {
        var draft = AddDraft(folder: URL(filePath: "/tmp"), segmentCount: 4)
        #expect(draft.links.isEmpty)
        draft.linksText = "https://example.com/a\nhttps://example.com/b"
        #expect(draft.links.count == 2)
        draft.linksText += "\nhttps://example.com/c"
        #expect(draft.links.count == 3)
        draft.linksText = ""
        #expect(draft.links.isEmpty)
    }

    @Test func closingTheSheetForgetsSecrets() {
        let ctx = makeModel()
        ctx.model.presentAddSheet(links: [URL(string: "https://example.com/a")!])
        ctx.model.draft.password = "hunter2"
        ctx.model.draft.cookies = "session=abc"
        ctx.model.showAddSheet = false
        ctx.model.resetDraft() // what the sheet's onDismiss does
        #expect(ctx.model.draft.password.isEmpty && ctx.model.draft.cookies.isEmpty && ctx.model.draft.links.isEmpty)
    }

    // MARK: Incoming files

    @Test func anUnreadableOrOversizedLinkFileSaysWhyInsteadOfNoLinks() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "big-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appending(path: "huge.txt")
        try Data(count: LinkParser.maxFileSize + 1).write(to: big)

        let resolution = await IncomingLinks.resolve([big])
        #expect(resolution.links.isEmpty)
        #expect(resolution.problems.first?.contains("huge.txt") == true && resolution.problems.first?.contains("larger") == true, "\(resolution.problems)")

        let ctx = makeModel()
        ctx.model.handleIncoming(urls: [big])
        #expect(await eventually { ctx.model.alert != nil })
        #expect(ctx.model.alert?.message.contains("larger") == true)
        #expect(!ctx.model.showAddSheet)
    }

    // MARK: Completion announcements

    @Test func downloadsRestoredAsFinishedAreNotAnnouncedButOnesFinishedNowAre() async {
        let ctx = makeModel()
        var announced: [String] = []
        ctx.model.onCompleted = { announced.append($0.displayName) }
        var old = snapshot("old.zip", state: .completed); old.completedAt = Date(timeIntervalSinceNow: -3600)
        var fresh = snapshot("fresh.zip", state: .completed); fresh.completedAt = Date()
        #expect(await started([old, fresh], ctx))
        #expect(announced == ["fresh.zip"])
        await ctx.model.shutdown()
    }

    // MARK: Start-up order

    @Test func limitsAreAppliedBeforeAnythingIsLoaded() async {
        let ctx = makeModel { $0.maxConcurrentDownloads = 2; $0.speedLimitKBps = 100 }
        ctx.model.start()
        _ = await eventually { await ctx.engine.calls.contains("load") }
        let calls = await ctx.engine.calls
        let load = calls.firstIndex(of: "load"), limit = calls.firstIndex(of: "globalLimit 100000")
        #expect(limit != nil && load != nil && limit! < load!, "\(calls)")
        await ctx.model.shutdown()
    }

    // MARK: Event inbox

    @Test func theInboxKeepsOnlyTheNewestEventPerDownloadNoMatterHowManyArrive() async {
        let inbox = EventInbox()
        let ids = (0..<3).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for n in 0..<2000 {
                        var s = snapshot("f.zip", total: 1_000_000, received: Int64(n))
                        s.id = ids[(worker + n) % 3]
                        inbox.put(.snapshot(s))
                    }
                }
            }
        }
        let events = inbox.take()
        #expect(events.count == 3, "16,000 events must collapse to one per download")
        #expect(inbox.take().isEmpty)
        inbox.put(.removed(ids[0]))
        inbox.put(.snapshot(snapshot("again.zip")))
        #expect(inbox.take().count == 2)
    }

    // MARK: Quitting and the window

    @Test func theSharedModelIsStartedByAppLaunchNotByTheWindow() async {
        // The test host launched the app; its delegate must have started the model whether or not any view appeared.
        #expect(await eventually { AppModel.shared.isStarted })
    }

    @Test func quittingRepliesOnceWhenShutdownFinishes() async {
        var replies = 0
        TerminationGate.run(shutdown: { try? await Task.sleep(for: .milliseconds(20)) }, timeout: .milliseconds(300)) { replies += 1 }
        try? await Task.sleep(for: .milliseconds(450))
        #expect(replies == 1, "the timeout must not reply a second time")
    }

    @Test func quittingCannotBeHeldUpByAStuckShutdown() async {
        var replies = 0
        let started = ContinuousClock.now
        TerminationGate.run(shutdown: { try? await Task.sleep(for: .seconds(60)) }, timeout: .milliseconds(150)) { replies += 1 }
        #expect(await eventually { replies == 1 })
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func aClosedMainWindowComesBackForIncomingLinks() async throws {
        let found = await eventually { NSApp.windows.contains { $0.identifier?.rawValue == MainWindow.sceneID } }
        try #require(found, "the test host should have created its main window")
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == MainWindow.sceneID })
        window.close() // what the red close button does
        #expect(!window.isVisible)
        #expect(MainWindow.showIfHidden(), "the window is gone from the screen, so it must be shown again")
        #expect(window.isVisible)
        #expect(!MainWindow.showIfHidden(), "and left alone when it is already visible")
    }

    // MARK: File categories

    @Test func theCategoryCacheNeverChangesAnAnswer() {
        let names = ["a.mkv", "a.MKV", "b.zip", "c.pdf", "d.weird1234", "e.mp3", "f.bin", "g.dmg"]
        let first = names.map { FileCategory.classify(filename: $0) }
        for _ in 0..<3 { #expect(names.map { FileCategory.classify(filename: $0) } == first) }
        // A flood of distinct extensions must neither crash nor corrupt the answers already known.
        for n in 0..<3000 { _ = FileCategory.classify(filename: "x.ext\(n)") }
        #expect(names.map { FileCategory.classify(filename: $0) } == first)
        #expect(first[0] == .video && first[1] == .video && first[2] == .archives && first[7] == .applications)
    }
}

