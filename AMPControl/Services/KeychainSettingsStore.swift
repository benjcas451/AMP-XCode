import Foundation
import Security

/// Keeps the connection settings in the iOS Keychain.
///
/// Service and account names are the ones the earlier Flutter app
/// (flutter_secure_storage) used, so credentials saved by it are found again.
struct KeychainSettingsStore: SettingsStore {
    var service = "flutter_secure_storage_service"

    private enum Key {
        static let settings = "amp_control_settings_v1"
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
        // Prefer the complete record; older Flutter/native entries remain readable.
        if let data = readData(Key.settings) {
            return (try? JSONDecoder().decode(ServerSettings.self, from: data)) ?? ServerSettings()
        }
        return ServerSettings(
            url: read(Key.url) ?? "",
            username: read(Key.username) ?? "",
            password: read(Key.password) ?? ""
        )
    }

    func save(_ settings: ServerSettings) throws {
        // A single keychain update commits all three values together.
        try write(JSONEncoder().encode(settings), for: Key.settings)
    }

    func clear() throws {
        let all: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(all as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }

    private func query(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }

    private func read(_ key: String) -> String? {
        readData(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func readData(_ key: String) -> Data? {
        var search = query(key)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return data
    }

    private func write(_ data: Data, for key: String) throws {
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
