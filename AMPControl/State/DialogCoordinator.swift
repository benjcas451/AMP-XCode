import Foundation
import Observation

struct ConfirmationPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var isDestructive = false
}

struct TextPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var message = ""
    var placeholder: String
    var initialText = ""
    var confirmLabel: String
}

/// Lets a view model ask the user something in the middle of an async flow:
/// it publishes the prompt, the view shows it as an alert and reports back.
@MainActor
@Observable
final class DialogCoordinator {
    /// The prompt on screen. Kept after it was answered so that the alert can
    /// still show its texts while it animates out.
    private(set) var confirmation: ConfirmationPrompt?
    private(set) var isConfirming = false

    private(set) var textPrompt: TextPrompt?
    private(set) var isRequestingText = false

    /// The text being edited in the current text prompt.
    var text = ""

    @ObservationIgnored private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var textContinuation: CheckedContinuation<String?, Never>?

    /// Shows a confirmation and waits for the user's answer.
    func confirm(_ prompt: ConfirmationPrompt) async -> Bool {
        answerConfirmation(false)
        confirmation = prompt
        isConfirming = true
        return await withCheckedContinuation { confirmationContinuation = $0 }
    }

    func answerConfirmation(_ confirmed: Bool) {
        isConfirming = false
        let continuation = confirmationContinuation
        confirmationContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    /// Asks for a line of text. Returns `nil` when the user cancels.
    func requestText(_ prompt: TextPrompt) async -> String? {
        answerText(nil)
        text = prompt.initialText
        textPrompt = prompt
        isRequestingText = true
        return await withCheckedContinuation { textContinuation = $0 }
    }

    func answerText(_ value: String?) {
        isRequestingText = false
        let continuation = textContinuation
        textContinuation = nil
        continuation?.resume(returning: value)
    }

    /// Cancels the prompt with this ID if it is still unanswered. Used when
    /// the alert went away without one of its buttons having answered.
    func cancel(promptID: UUID) {
        if isConfirming, confirmation?.id == promptID { answerConfirmation(false) }
        if isRequestingText, textPrompt?.id == promptID { answerText(nil) }
    }
}
