import Foundation
import Observation

/// State and actions of the instance list.
@MainActor
@Observable
final class InstancesViewModel {
    private(set) var instances: [AMPInstance]?
    private(set) var error: String?
    private(set) var actions = InstanceActionController()

    let dialogs = DialogCoordinator()

    @ObservationIgnored private let client: AMPClient
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let isActive: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private var loadVersion = 0

    /// - Parameters:
    ///   - isActive: Whether this list is still the one on screen. Results that
    ///     arrive after it was replaced (new settings) are dropped.
    ///   - sleep: Waits between status checks; replaced in tests.
    init(
        client: AMPClient,
        toasts: ToastCenter,
        isActive: @escaping @MainActor () -> Bool = { true },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.toasts = toasts
        self.isActive = isActive
        self.sleep = sleep
    }

    /// `nil` when no action is running, otherwise whether it is a start.
    func pendingStart(_ instance: AMPInstance) -> Bool? {
        actions.isBusy(instance.id) ? actions.isPendingStart(instance.id) : nil
    }

    func load() async {
        loadVersion += 1
        let version = loadVersion
        do {
            let list = try await client.getInstances()
            guard isActive(), version == loadVersion else { return }
            instances = list
            error = nil
        } catch let failure as AMPError {
            guard isActive(), version == loadVersion else { return }
            error = failure.message
        } catch {}
    }

    /// Reloads every 10 seconds until the surrounding task is cancelled.
    func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Handles a tap on an instance. Returns `true` when its detail screen
    /// should open; an instance that is not running is offered to be started
    /// instead.
    func open(_ instance: AMPInstance) async -> Bool {
        if actions.isLocked(instance.id) { return false }
        if !instance.running {
            await setInstanceRunning(instance, running: true, confirmStart: true)
            return false
        }
        return true
    }

    func toggle(_ instance: AMPInstance) async {
        await setInstanceRunning(instance, running: !instance.running)
    }

    func setInstanceRunning(_ instance: AMPInstance, running: Bool, confirmStart: Bool = false)
        async
    {
        let id = instance.id
        if actions.isLocked(id) { return }
        defer { if isActive() { actions.finish(id) } }
        do {
            if !running || confirmStart {
                actions.beginConfirmation(id)
                let confirmed = await dialogs.confirm(
                    ConfirmationPrompt(
                        title: running ? "Instanz starten?" : "Instanz stoppen?",
                        message: running
                            ? "\(instance.displayName): Die AMP-Instanz ist nicht gestartet. Jetzt starten?"
                            : "\(instance.displayName): Die gesamte AMP-Instanz wird gestoppt. "
                                + "Ein laufender Server wird dabei ebenfalls beendet.",
                        confirmLabel: running ? "Instanz starten" : "Instanz stoppen",
                        isDestructive: !running
                    ))
                if !confirmed {
                    actions.clearConfirmation(id)
                    return
                }
            }
            guard isActive() else { return }
            actions.beginBusy(id, running: running)
            if running {
                try await client.startInstanceProcess(instance)
            } else {
                try await client.stopInstanceProcess(instance)
            }
            guard isActive() else { return }
            toasts.show(running ? "Instanz wird gestartet …" : "Instanz wird gestoppt …")
            // Keep controls disabled until ADS reports the actual process state.
            for attempt in 0...15 {
                await load()
                guard isActive() else { return }
                if instances?.contains(where: { $0.id == id && $0.running == running }) == true {
                    return
                }
                if attempt == 15 { break }
                await sleep(.seconds(2))
                guard isActive() else { return }
            }
            toasts.show(
                "Der Statuswechsel wurde noch nicht bestätigt. "
                    + "Bitte die Instanzliste aktualisieren.")
        } catch let failure as AMPError {
            if isActive() { toasts.show(failure.message) }
        } catch {}
    }
}
