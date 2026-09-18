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
            Button("Show in Finder") { model.revealInFinder(model.selection) }
                .keyboardShortcut("r")
                .disabled(!model.canRevealSelection)
            // No shortcut here: a global ⌘⌫ would also fire while typing in a text field. The Delete key
            // works in the table itself.
            Button("Remove from List") { model.requestRemoval(model.selection) }
                .disabled(model.selectedDownloads.isEmpty)
        }
    }
}
