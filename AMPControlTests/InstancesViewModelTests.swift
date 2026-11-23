import Foundation
import Testing

@testable import AMPControl

/// An ADS with a single Minecraft instance whose process can be started and
/// stopped.
@MainActor
private final class FakeADS {
    var running = false
    /// Whether a start/stop is reflected in the instance list right away.
    var updateImmediately = true
    var actionError: String?
    var actionGate: Gate?
    var starts = 0
    var stops = 0

    func transport() -> MockTransport {
        MockTransport { [self] request in
            switch request.method {
            case "Core/Login":
                return .json(["success": true, "sessionID": "session"])
            case "ADSModule/GetInstances":
                return .json([
                    [
                        "AvailableInstances": [
                            [
                                "InstanceID": "mc",
                                "InstanceName": "Minecraft01",
                                "FriendlyName": "Survival",
                                "Module": "Minecraft",
                                "Running": .bool(running),
                                "AppState": 10,
                            ]
                        ]
                    ]
                ])
            case "ADSModule/StartInstance":
                starts += 1
                return await change(to: true)
            case "ADSModule/StopInstance":
                stops += 1
                return await change(to: false)
            default:
                return .text("not found", status: 404)
            }
        }
    }

    private func change(to value: Bool) async -> HTTPResponse {
        await actionGate?.wait()
        if let actionError { return .json(["Status": false, "Reason": .string(actionError)]) }
        if updateImmediately { running = value }
        return .json(["Status": true])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class InstancesViewModelTests {
    private let ads = FakeADS()
    private let toasts = ToastCenter()
    private var active = true
    private var sleeps = 0
    /// When set, the model's waits between status checks block on it.
    private var sleepGate: Gate?
    private var model: InstancesViewModel!

    init() async {
        let client = AMPClient(
            baseURL: "http://amp.local", username: "", password: "", transport: ads.transport())
        model = InstancesViewModel(
            client: client,
            toasts: toasts,
            isActive: { [unowned self] in active },
            sleep: { [unowned self] _ in
                sleeps += 1
                await sleepGate?.wait()
            })
        await model.load()
    }

    private var instance: AMPInstance {
        get throws { try #require(model.instances?.first) }
    }

    private var locked: Bool { model.actions.isLocked("mc") }

    // MARK: - Tests

    @Test func startsAnOfflineInstanceDirectlyAndSeparatesStatus() async throws {
        #expect(try !instance.running)
        try await model.toggle(instance)
        #expect(ads.starts == 1)
        #expect(!model.dialogs.isConfirming)
        #expect(try instance.running)
        // The instance process runs while its game server is still stopped.
        #expect(try instance.appState == .stopped)
        #expect(toasts.current?.text == "Instanz wird gestartet …")
        #expect(!locked)
    }

    @Test func stopRequiresConfirmationAndCanBeCancelled() async throws {
        ads.running = true
        await model.load()
        let running = try instance

        let cancelled = Task { await model.toggle(running) }
        await waitUntil("the confirmation is shown") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.message.contains("Ein laufender Server") == true)
        #expect(locked)
        #expect(ads.stops == 0)
        model.dialogs.answerConfirmation(false)
        await cancelled.value
        #expect(ads.stops == 0)
        #expect(!locked)

        let confirmed = Task { await model.toggle(running) }
        await waitUntil("the confirmation is shown") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.confirmLabel == "Instanz stoppen")
        model.dialogs.answerConfirmation(true)
        await confirmed.value
        #expect(ads.stops == 1)
        #expect(try !instance.running)
        #expect(!locked)
    }

    @Test func locksActionsUntilADSConfirmsTheProcessState() async throws {
        ads.updateImmediately = false
        let gate = Gate()
        sleepGate = gate
        let stopped = try instance

        let action = Task { await model.toggle(stopped) }
        await waitUntil("the model waits for ADS") { gate.waiters == 1 }
        #expect(model.pendingStart(stopped) == true)
        #expect(locked)

        // Neither a tap on the instance nor another toggle gets through.
        #expect(await model.open(stopped) == false)
        await model.toggle(stopped)
        #expect(ads.starts == 1)
        #expect(!model.dialogs.isConfirming)

        ads.running = true
        gate.open()
        await action.value
        #expect(try instance.running)
        #expect(model.pendingStart(stopped) == nil)
        #expect(!locked)
    }

    @Test func reportsFailuresAndAllowsAnotherAttempt() async throws {
        ads.actionError = "Keine Berechtigung"
        try await model.toggle(instance)
        #expect(toasts.current?.text == "Keine Berechtigung")
        #expect(try !instance.running)
        #expect(!locked)

        ads.actionError = nil
        try await model.toggle(instance)
        #expect(ads.starts == 2)
        #expect(try instance.running)
    }

    @Test func timesOutWithoutFalselyReportingARunningInstance() async throws {
        ads.updateImmediately = false
        try await model.toggle(instance)
        #expect(sleeps == 15)
        #expect(toasts.current?.text.contains("noch nicht bestätigt") == true)
        #expect(try !instance.running)
        #expect(!locked)
        #expect(ads.starts == 1)
    }

    @Test func staysSilentWhenTheScreenIsGoneBeforeAnActionCompletes() async throws {
        let gate = Gate()
        ads.actionGate = gate
        let stopped = try instance

        let action = Task { await model.toggle(stopped) }
        await waitUntil("the start request is in flight") { gate.waiters == 1 }
        active = false
        gate.open()
        await action.value
        #expect(ads.starts == 1)
        #expect(toasts.current == nil)
        #expect(try !instance.running)
    }

    @Test func tappingAnOfflineInstanceOffersToStartIt() async throws {
        let stopped = try instance
        let tap = Task { await model.open(stopped) }
        await waitUntil("the confirmation is shown") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.title == "Instanz starten?")
        model.dialogs.answerConfirmation(true)
        #expect(await tap.value == false)
        #expect(ads.starts == 1)
        #expect(try instance.running)
    }

    @Test func tappingARunningInstanceOpensIt() async throws {
        ads.running = true
        await model.load()
        #expect(try await model.open(instance))
        #expect(ads.starts == 0)
        #expect(!model.dialogs.isConfirming)
    }

    @Test func loadErrorsKeepTheLastKnownList() async throws {
        #expect(model.error == nil)
        ads.actionError = nil
        let failing = InstancesViewModel(
            client: AMPClient(
                baseURL: "http://amp.local", username: "", password: "",
                transport: MockTransport { _ in throw TransportError.timedOut }),
            toasts: toasts)
        await failing.load()
        #expect(failing.instances == nil)
        #expect(failing.error == "Zeitüberschreitung – Server nicht erreichbar.")
    }

    @Test func actionControllerTracksPendingStatesAndConfirmationLocks() {
        var controller = InstanceActionController()
        #expect(!controller.isLocked("mc"))

        controller.beginConfirmation("mc")
        #expect(controller.isConfirming("mc"))
        #expect(controller.isLocked("mc"))

        controller.clearConfirmation("mc")
        #expect(!controller.isConfirming("mc"))
        #expect(!controller.isLocked("mc"))

        controller.beginBusy("mc", running: true)
        #expect(controller.isBusy("mc"))
        #expect(controller.isPendingStart("mc"))
        #expect(!controller.isPendingStop("mc"))
        #expect(controller.isLocked("mc"))

        controller.finish("mc")
        #expect(!controller.isBusy("mc"))
        #expect(!controller.isLocked("mc"))
    }
}
