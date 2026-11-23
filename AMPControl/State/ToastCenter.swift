import Foundation
import Observation

/// A short message shown at the bottom of the screen.
struct Toast: Identifiable, Equatable, Sendable {
    let id = UUID()
    var text: String
    var isError = false
}

/// Shows one toast at a time; a newer one replaces the current one.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?

    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private let duration: Duration

    init(duration: Duration = .seconds(4)) {
        self.duration = duration
    }

    func show(_ text: String, isError: Bool = false) {
        let toast = Toast(text: text, isError: isError)
        current = toast
        dismissal?.cancel()
        dismissal = Task { [duration] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled, current?.id == toast.id { current = nil }
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}
