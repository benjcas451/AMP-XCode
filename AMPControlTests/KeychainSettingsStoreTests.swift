import Foundation
import Security
import Testing

@testable import AMPControl

struct KeychainSettingsStoreTests {
    @Test func legacySettingsAreReadAndReplacedByOneCompleteRecord() throws {
        let store = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        defer { try? store.clear() }
        for (key, value) in ["server_url": "old", "username": "old-user", "password": "old-password"] {
            let item: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: store.service,
                kSecAttrAccount: key,
                kSecValueData: Data(value.utf8),
            ]
            #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        }
        #expect(store.load() == ServerSettings(url: "old", username: "old-user", password: "old-password"))
        let updated = ServerSettings(url: "new", username: "new-user", password: "new-password")
        try store.save(updated)
        #expect(store.load() == updated)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: store.service,
            kSecAttrAccount: "amp_control_settings_v1",
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let data = try #require(item as? Data)
        #expect(try JSONDecoder().decode(ServerSettings.self, from: data) == updated)
        try store.clear()
        #expect(store.load() == ServerSettings())
        try store.clear() // An already empty keychain is also a successful clear.
    }

    @Test func savesLoadsAndClearsSettings() throws {
        let store = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        defer { try? store.clear() }
        #expect(store.load() == ServerSettings())

        let settings = ServerSettings(
            url: "http://192.168.1.10:8080", username: "admin", password: "pässwört")
        try store.save(settings)
        #expect(store.load() == settings)

        let changed = ServerSettings(url: "https://amp.example.com", username: "app", password: "x")
        try store.save(changed)
        #expect(store.load() == changed)

        try store.clear()
        #expect(store.load() == ServerSettings())
    }

    @Test func servicesAreKeptApart() throws {
        let first = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        let second = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        defer {
            try? first.clear()
            try? second.clear()
        }
        try first.save(ServerSettings(url: "a", username: "b", password: "c"))
        #expect(second.load() == ServerSettings())
        try second.clear()
        #expect(first.load().url == "a")
    }
}
