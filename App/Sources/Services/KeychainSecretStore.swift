import DownloadKit
import Foundation
import Security

/// Keeps per-download cookies, custom headers and passwords in the login keychain rather than in the
/// job files. One generic-password item per download.
struct KeychainSecretStore: SecretStore {
    let service: String

    func secrets(for id: DownloadID) async -> SensitiveOptions? {
        var query = baseQuery(for: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SensitiveOptions.self, from: data)
    }

    func setSecrets(_ secrets: SensitiveOptions, for id: DownloadID) async throws {
        let data = try JSONEncoder().encode(secrets)
        SecItemDelete(baseQuery(for: id) as CFDictionary)
        var item = baseQuery(for: id)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DownloadError.fileSystem(String(localized: "Could not save credentials to the keychain (status \(status))."))
        }
    }

    func removeSecrets(for id: DownloadID) async {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    private func baseQuery(for id: DownloadID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }
}
