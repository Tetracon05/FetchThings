import Foundation

/// Holds cookies, custom headers and Basic-auth credentials, kept apart from the job store. The app
/// supplies a Keychain-backed implementation; the in-memory one loses secrets on quit. A download added
/// with secrets (`DownloadRecord.hasSecrets`) fails with `credentialsUnavailable` when they cannot be read
/// back, rather than carrying on without them.
public protocol SecretStore: Sendable {
    func secrets(for id: DownloadID) async -> SensitiveOptions?
    func setSecrets(_ secrets: SensitiveOptions, for id: DownloadID) async throws
    func removeSecrets(for id: DownloadID) async
}

public actor InMemorySecretStore: SecretStore {
    private var storage: [DownloadID: SensitiveOptions] = [:]

    public init() {}

    public func secrets(for id: DownloadID) -> SensitiveOptions? { storage[id] }
    public func setSecrets(_ secrets: SensitiveOptions, for id: DownloadID) { storage[id] = secrets }
    public func removeSecrets(for id: DownloadID) { storage[id] = nil }
}
