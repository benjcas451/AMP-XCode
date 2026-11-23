/// Tracks which instances have a start/stop in flight (or awaiting
/// confirmation), so their controls stay locked until it is settled.
struct InstanceActionController: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var busy = false
        var confirming = false
        var targetRunning = false
    }

    private var entries: [String: Entry] = [:]

    func isLocked(_ id: String) -> Bool { isConfirming(id) || isBusy(id) }
    func isConfirming(_ id: String) -> Bool { entries[id]?.confirming == true }
    func isBusy(_ id: String) -> Bool { entries[id]?.busy == true }

    func isPendingStart(_ id: String) -> Bool {
        entries[id]?.busy == true && entries[id]?.targetRunning == true
    }

    func isPendingStop(_ id: String) -> Bool {
        entries[id]?.busy == true && entries[id]?.targetRunning == false
    }

    mutating func beginConfirmation(_ id: String) {
        entries[id, default: Entry()].confirming = true
    }

    mutating func clearConfirmation(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.confirming = false
        entries[id] = entry.busy ? entry : nil
    }

    mutating func beginBusy(_ id: String, running: Bool) {
        entries[id] = Entry(busy: true, confirming: false, targetRunning: running)
    }

    mutating func finish(_ id: String) {
        entries[id] = nil
    }

    mutating func clearAll() {
        entries.removeAll()
    }
}
