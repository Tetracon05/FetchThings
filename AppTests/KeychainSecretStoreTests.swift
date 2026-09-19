import DownloadKit
import Foundation
import Testing
@testable import FetchThings

@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    private func makeStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "com.example.FetchThingsTests.\(UUID().uuidString)")
    }

    private let secrets = SensitiveOptions(
        cookies: "session=abc",
        headers: ["Authorization": "Bearer t0k3n", "X-Key": "v"],
        basicAuth: BasicAuth(username: "ann", password: "p@ss:word")
    )

    @Test func roundTripsEverything() async throws {
        let store = makeStore(), id = UUID()
        defer { Task { await store.removeSecrets(for: id) } }
        try await store.setSecrets(secrets, for: id)
        #expect(await store.secrets(for: id) == secrets)
    }

    @Test func overwritingReplacesTheOldValue() async throws {
        let store = makeStore(), id = UUID()
        defer { Task { await store.removeSecrets(for: id) } }
        try await store.setSecrets(secrets, for: id)
        try await store.setSecrets(SensitiveOptions(cookies: "new=1"), for: id)
        #expect(await store.secrets(for: id) == SensitiveOptions(cookies: "new=1"))
    }

    @Test func removalAndMissingItems() async throws {
        let store = makeStore(), id = UUID()
        #expect(await store.secrets(for: id) == nil)
        try await store.setSecrets(secrets, for: id)
        await store.removeSecrets(for: id)
        #expect(await store.secrets(for: id) == nil)
        await store.removeSecrets(for: id) // removing twice is harmless
    }

    @Test func itemsAreKeptPerDownloadAndPerService() async throws {
        let store = makeStore(), other = makeStore()
        let a = UUID(), b = UUID()
        defer { Task { await store.removeSecrets(for: a); await store.removeSecrets(for: b); await other.removeSecrets(for: a) } }
        try await store.setSecrets(SensitiveOptions(cookies: "a"), for: a)
        try await store.setSecrets(SensitiveOptions(cookies: "b"), for: b)
        #expect(await store.secrets(for: a)?.cookies == "a")
        #expect(await store.secrets(for: b)?.cookies == "b")
        #expect(await other.secrets(for: a) == nil, "another service must not see it")
    }
}
