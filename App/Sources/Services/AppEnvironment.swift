import AppKit
import DownloadKit
import Foundation

/// Builds the real engine. When the app is hosting unit tests it must not touch the user's downloads,
/// job files or keychain, so it gets throwaway storage instead.
@MainActor
enum AppEnvironment {
    /// UI testing only: in sandbox mode, `FETCHTHINGS_APPEARANCE=dark|light` forces an appearance without touching the
    /// system's settings.
    static var forcedAppearance: NSAppearance? {
        guard sandboxDirectory != nil, let name = ProcessInfo.processInfo.environment["FETCHTHINGS_APPEARANCE"] else { return nil }
        return NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// For driving the app by hand or by script: `FETCHTHINGS_SANDBOX=<folder>` keeps the job list, downloaded files,
    /// secrets and settings away from the real ones (jobs in `<folder>/Jobs`, files in `<folder>/Downloads`).
    static var sandboxDirectory: URL? {
        ProcessInfo.processInfo.environment["FETCHTHINGS_SANDBOX"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func makeModel() -> AppModel {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.FetchThings"
        let defaults: UserDefaults
        let jobsDirectory: URL
        let secrets: any SecretStore

        if let sandbox = sandboxDirectory {
            let suite = "\(bundleID).sandbox"
            UserDefaults().removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
            let downloads = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            defaults.set(downloads.path, forKey: "downloadFolder")
            jobsDirectory = sandbox.appending(path: "Jobs", directoryHint: .isDirectory)
            secrets = InMemorySecretStore()
        } else if isRunningTests {
            defaults = UserDefaults(suiteName: "\(bundleID).tests.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
            jobsDirectory = URL(filePath: NSTemporaryDirectory()).appending(path: "FetchThingsTestHost-\(ProcessInfo.processInfo.processIdentifier)/Jobs")
            secrets = InMemorySecretStore()
        } else {
            defaults = .standard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            jobsDirectory = support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Jobs", directoryHint: .isDirectory)
            secrets = KeychainSecretStore(service: bundleID)
        }

        let settings = AppSettings(defaults: defaults)
        let manager = DownloadManager(store: FileJobStore(directory: jobsDirectory), secrets: secrets, network: networkMonitor())
        return AppModel(engine: manager, settings: settings)
    }

    /// The system's network, except under unit tests (nothing is held back) and, for a UI test in sandbox mode,
    /// `FETCHTHINGS_NETWORK_FILE=<file>`: the network is what the file says (`offline`, `expensive`, `constrained`;
    /// anything else is online), so a screenshot run can change it without touching the Mac's real connection.
    private static func networkMonitor() -> (any NetworkMonitoring)? {
        if isRunningTests { return nil }
        if sandboxDirectory != nil, let path = ProcessInfo.processInfo.environment["FETCHTHINGS_NETWORK_FILE"] {
            return FileNetworkMonitor(file: URL(filePath: path))
        }
        return SystemNetworkMonitor()
    }
}
