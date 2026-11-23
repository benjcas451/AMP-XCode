import Foundation
import Testing

@testable import AMPControl

struct ModelTests {
    @Test func stateCodesArriveAsNumbersOrStrings() {
        #expect(ApplicationState(code: 20) == .ready)
        #expect(ApplicationState(code: "75") == .updating)
        #expect(ApplicationState(code: 12345) == .undefined)
        #expect(ApplicationState(code: nil) == .undefined)
        #expect(ApplicationState.starting.isBusy)
        #expect(!ApplicationState.sleeping.isBusy)
        #expect(ApplicationState.failed.isStopped)
    }

    /// AMP's own codes. A running server (`Ready` = 20) was once read as
    /// starting, and a stopped one (0) as unknown.
    @Test func stateCodesMatchAMP() {
        #expect(ApplicationState(code: 0) == .stopped)
        #expect(ApplicationState(code: 5) == .preStart)
        #expect(ApplicationState(code: 10) == .starting)
        #expect(ApplicationState(code: 20) == .ready)
        #expect(ApplicationState(code: 20).label == "Läuft")
        #expect(ApplicationState(code: 30) == .restarting)
        #expect(ApplicationState(code: 40) == .stopping)
        #expect(ApplicationState(code: 50) == .sleeping)
        #expect(ApplicationState(code: 100) == .failed)
        #expect(ApplicationState(code: -1) == .undefined)
        #expect(ApplicationState(code: 999) == .undefined)
    }

    @Test func metricsFormatTheirValues() throws {
        let memory = try Metric(
            name: "Memory Usage",
            json: ["RawValue": 1536, "MaxValue": 4096, "Percent": 37.5, "Units": "MB"])
        #expect(memory.label == "RAM")
        #expect(memory.valueText == "1536 / 4096 MB")
        #expect(memory.fraction == 0.375)

        let users = try Metric(name: "Active Users", json: ["RawValue": 3, "Percent": 150])
        #expect(users.valueText == "3")
        #expect(users.fraction == 1)
    }

    @Test func metricsKeepAStableOrder() throws {
        let metrics = try Metric.list(from: [
            "Active Users": [:], "TPS": [:], "Memory Usage": [:], "CPU Usage": [:],
        ])
        #expect(metrics.map(\.label) == ["CPU", "RAM", "Spieler", "TPS"])
    }

    @Test func datesAreReadInBothAMPFormats() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AMPDate.parse("/Date(1700000000000)/") == reference)
        #expect(AMPDate.parse("2023-11-14T22:13:20Z") == reference)
        #expect(AMPDate.parse("2023-11-14T23:13:20+01:00") == reference)
        #expect(AMPDate.parse("2023-11-14 22:13:20.500Z") == reference.addingTimeInterval(0.5))
        #expect(AMPDate.parse("not a date") == nil)
        #expect(AMPDate.parse(nil) == nil)

        // Without a zone the time is local.
        let local = try #require(AMPDate.parse("2023-11-14T22:13:20"))
        #expect(AMPDate.clockTime(local) == "22:13:20")
    }

    @Test func sizesAreLenientAndReadable() {
        #expect(ByteSize.parse(2048) == 2048)
        #expect(ByteSize.parse(" 512 ") == 512)
        #expect(ByteSize.parse("1.9e3") == 1900)
        #expect(ByteSize.parse("big") == 0)
        #expect(ByteSize.parse(nil) == 0)
        #expect(ByteSize.label(0) == "")
        #expect(ByteSize.label(512) == "512 B")
        #expect(ByteSize.label(2048) == "2.0 KB")
        #expect(ByteSize.label(5 * 1024 * 1024) == "5.0 MB")
    }

    @Test func filesRecogniseDirectoriesInAllSpellings() {
        #expect(FileEntry(json: ["Filename": "a", "IsDirectory": true]).isDirectory)
        #expect(FileEntry(json: ["Filename": "a", "IsFolder": "true"]).isDirectory)
        #expect(FileEntry(json: ["Filename": "a", "Type": "Directory"]).isDirectory)
        #expect(!FileEntry(json: ["Filename": "a", "IsDirectory": false]).isDirectory)
    }

    @Test func settingsValuesOfAnyTypeBecomeText() {
        #expect(SettingEntry(json: ["Node": "n", "CurrentValue": 20]).value == "20")
        #expect(SettingEntry(json: ["Node": "n", "CurrentValue": true]).value == "true")
        #expect(SettingEntry(json: ["Node": "n", "CurrentValue": ["a", "b"]]).value == "[a, b]")
        // A present but empty current value does not fall back to `Value`.
        #expect(SettingEntry(json: ["Node": "n", "CurrentValue": .null, "Value": "x"]).value == "")
    }
}
