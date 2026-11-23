import Foundation
import Testing

@testable import AMPControl

struct KeychainSettingsStoreTests {
    @Test func savesLoadsAndClearsSettings() throws {
        let store = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        defer { store.clear() }
        #expect(store.load() == ServerSettings())

        let settings = ServerSettings(
            url: "http://192.168.1.10:8080", username: "admin", password: "pässwört")
        try store.save(settings)
        #expect(store.load() == settings)

        let changed = ServerSettings(url: "https://amp.example.com", username: "app", password: "x")
        try store.save(changed)
        #expect(store.load() == changed)

        store.clear()
        #expect(store.load() == ServerSettings())
    }

    @Test func servicesAreKeptApart() throws {
        let first = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        let second = KeychainSettingsStore(service: "amp-control-tests-\(UUID().uuidString)")
        defer {
            first.clear()
            second.clear()
        }
        try first.save(ServerSettings(url: "a", username: "b", password: "c"))
        #expect(second.load() == ServerSettings())
        second.clear()
        #expect(first.load().url == "a")
    }
}
