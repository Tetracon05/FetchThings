import DownloadKit
import Foundation

/// Builds the real engine. When the app is hosting unit tests it must not touch the user's downloads,
/// job files or keychain, so it gets throwaway storage instead.
@MainActor
enum AppEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func makeModel() -> AppModel {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.Downloader"
        let defaults: UserDefaults
        let jobsDirectory: URL
        let secrets: any SecretStore

        if isRunningTests {
            defaults = UserDefaults(suiteName: "\(bundleID).tests.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
            jobsDirectory = URL(filePath: NSTemporaryDirectory()).appending(path: "DownloaderTestHost-\(ProcessInfo.processInfo.processIdentifier)/Jobs")
            secrets = InMemorySecretStore()
        } else {
            defaults = .standard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            jobsDirectory = support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Jobs", directoryHint: .isDirectory)
            secrets = KeychainSecretStore(service: bundleID)
        }

        let settings = AppSettings(defaults: defaults)
        let manager = DownloadManager(store: FileJobStore(directory: jobsDirectory), secrets: secrets)
        return AppModel(engine: manager, settings: settings)
    }
}
