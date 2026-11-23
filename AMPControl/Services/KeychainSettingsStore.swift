import Foundation
import Security

/// Keeps the connection settings in the iOS Keychain.
///
/// Service and account names are the ones the earlier Flutter app
/// (flutter_secure_storage) used, so credentials saved by it are found again.
struct KeychainSettingsStore: SettingsStore {
    var service = "flutter_secure_storage_service"

    private enum Key {
        static let url = "server_url"
        static let username = "username"
        static let password = "password"
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Schlüsselbund-Fehler: \(detail)"
        }
    }

    func load() -> ServerSettings {
        ServerSettings(
            url: read(Key.url) ?? "",
            username: read(Key.username) ?? "",
            password: read(Key.password) ?? ""
        )
    }

    func save(_ settings: ServerSettings) throws {
        try write(settings.url, for: Key.url)
        try write(settings.username, for: Key.username)
        try write(settings.password, for: Key.password)
    }

    func clear() {
        let all: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(all as CFDictionary)
    }

    private func query(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }

    private func read(_ key: String) -> String? {
        var search = query(key)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            query(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainError(status: status) }
    }
}
