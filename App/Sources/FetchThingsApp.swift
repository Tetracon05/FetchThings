import SwiftUI

@main
struct FetchThingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        // A single window: opening a link or file with the app must not spawn another one.
        Window("Downloads", id: MainWindow.sceneID) {
            MainView(model: model)
                .frame(minWidth: MainWindowLayout.minWindowWidth, minHeight: MainWindowLayout.minWindowHeight)
        }
        .defaultSize(width: 1100, height: 640)
        .commands { DownloadCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}

extension AppModel {
    /// The one model the app runs on. The app delegate needs it too, for Dock drops and Services.
    static let shared = AppEnvironment.makeModel()
}
