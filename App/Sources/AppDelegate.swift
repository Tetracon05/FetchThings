import AppKit
import QuickLookUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // Not tied to the window: downloads resume and are observed even if the window never appears.
        // UI testing only (sandbox mode): force an appearance without touching system settings.
        if AppEnvironment.sandboxDirectory != nil, let name = ProcessInfo.processInfo.environment["DOWNLOADER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        AppModel.shared.start()
    }

    /// Links and text files dropped on the Dock icon, files opened with the app, and `downloader://` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.handleIncoming(urls: urls)
        MainWindow.showIfHidden() // the Add sheet lives in the window, so a closed window would swallow it
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.showIfHidden() }
        return true
    }

    // Quick Look (Space in the table) asks the responder chain, the app delegate included, who runs its preview panel.
    // Quick Look calls these on the main thread; the overrides are not main-actor isolated, so say so.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.attach(to: panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.detach(from: panel) }
    }

    /// Stop the transfers and save their progress before quitting, but never hang the quit on it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminationGate.run(shutdown: { await AppModel.shared.shutdown() }, timeout: .seconds(8)) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Brings the main window back after it was closed. The app keeps running with no window, and the Add sheet
/// belongs to that window.
@MainActor
enum MainWindow {
    /// The scene id in `DownloaderApp`; SwiftUI uses it as the window's identifier. (Looking the window up by
    /// `canBecomeMain` would miss it exactly when it is hidden, because SwiftUI reports false then.)
    static let sceneID = "main"

    /// Orders the main window to the front if it is not on screen. Returns whether it was hidden.
    @discardableResult
    static func showIfHidden() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == sceneID }), !window.isVisible else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Replies to the system's "may I quit?" question exactly once: when shutdown finishes, or when `timeout`
/// passes, whichever comes first.
@MainActor
final class TerminationGate {
    private var replied = false
    private let reply: @MainActor () -> Void

    private init(reply: @escaping @MainActor () -> Void) {
        self.reply = reply
    }

    private func finish() {
        guard !replied else { return }
        replied = true
        reply()
    }

    static func run(
        shutdown: @escaping @MainActor () async -> Void,
        timeout: Duration,
        reply: @escaping @MainActor () -> Void
    ) {
        let gate = TerminationGate(reply: reply)
        Task { await shutdown(); gate.finish() }
        Task { try? await Task.sleep(for: timeout); gate.finish() }
    }
}

/// The "Add to Downloader" item in the Services menu: selected text with links in it goes to the Add sheet.
/// (macOS cannot deliver text dropped on a Dock icon, so this is the way to send text to the app.)
@MainActor
final class ServicesProvider: NSObject {
    @objc func addDownloads(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string) else { return }
        AppModel.shared.handleText(text)
        MainWindow.showIfHidden()
    }
}
