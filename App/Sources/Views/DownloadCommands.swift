import SwiftUI

struct DownloadCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Download…") { model.presentAddSheet() }
                .keyboardShortcut("n")
            Button("Add Link from Clipboard…") { model.addFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Details" : "Show Details") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("Search Downloads") { model.isSearchFocused = true }
                .keyboardShortcut("f")
        }
        // There is no help book; the default item would only report that help is unavailable.
        CommandGroup(replacing: .help) {}

        CommandMenu("Downloads") {
            Button("Pause") { model.pauseSelection() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.canPauseSelection)
            Button("Resume") { model.resumeSelection() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.canResumeSelection)
            Divider()
            Button("Pause All") { model.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Resume All") { model.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Picker("Speed Mode", selection: Binding(get: { model.settings.speedMode }, set: { model.selectSpeedMode($0) })) {
                ForEach(SpeedMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Divider()
            Button("Show in Finder") { model.revealInFinder(model.selection) }
                .keyboardShortcut("r")
                .disabled(!model.canRevealSelection)
            // Finder's own shortcut. Space does the same in the table (a plain Space here would also fire while
            // typing in a text field).
            Button("Quick Look") { QuickLookController.shared.toggle(for: model) }
                .keyboardShortcut("y")
                .disabled(!model.canQuickLookSelection)
            // No shortcut here: a global ⌘⌫ would also fire while typing in a text field. The Delete key
            // works in the table itself.
            Button("Remove from List") { model.requestRemoval(model.selection) }
                .disabled(model.selectedDownloads.isEmpty)
        }
    }
}
