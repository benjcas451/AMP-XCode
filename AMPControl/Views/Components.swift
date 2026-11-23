import SwiftUI

extension ApplicationState {
    var color: Color {
        switch self {
        case .undefined: .gray
        case .stopped, .failed: .red
        case .preStart, .configuring, .starting, .restarting, .stopping, .waiting: .orange
        case .ready: .green
        case .preparingForSleep, .sleeping: Color(red: 0.38, green: 0.49, blue: 0.55)
        case .installing, .updating: .blue
        case .awaitingUserInput: .yellow
        }
    }
}

/// Coloured pill with the server state; `nil` means the AMP instance process
/// itself is not running.
struct StateBadge: View {
    var state: ApplicationState?

    var body: some View {
        let color = state?.color ?? .gray
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(state?.label ?? "Instanz aus")
                .font(.caption)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(color))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Rounded surface for content placed on a grouped background.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Lays its subviews out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        // Wrap at the same width that `sizeThatFits` measured with. `bounds`
        // only spans the occupied width, rounded to the pixel grid, so
        // re-wrapping at it can push an item onto a row whose height was
        // never reserved, overlapping whatever follows the layout.
        let width = proposal.width ?? bounds.width
        let arrangement = arrange(subviews, width: width)
        for (index, frame) in arrangement.frames.enumerated() {
            // Subviews keep their ideal size; proposing that very size again
            // can truncate text by a rounding error. Only a subview wider
            // than a whole row is limited to the row.
            let fitsRow = frame.width < width
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: fitsRow ? .unspecified : ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var row: [Int] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        // Centres the finished row's items vertically and moves to the next row.
        func finishRow() {
            for index in row {
                frames[index].origin.y = y + (rowHeight - frames[index].height) / 2
            }
            if !row.isEmpty { y += rowHeight + lineSpacing }
            row = []
            x = 0
            rowHeight = 0
        }

        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width { finishRow() }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            row.append(index)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        let lastRowHeight = rowHeight
        let lastRowTop = y
        finishRow()
        return (CGSize(width: totalWidth, height: lastRowTop + lastRowHeight), frames)
    }
}

// MARK: - Toasts

private struct ToastOverlay: ViewModifier {
    let toasts: ToastCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = toasts.current {
                    Text(toast.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 480, alignment: .leading)
                        .background(
                            toast.isError ? Color.red : Color(white: 0.2),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .shadow(radius: 8, y: 2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .onTapGesture { toasts.dismiss() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                        .accessibilityIdentifier("toast")
                }
            }
            .animation(.snappy, value: toasts.current)
            .onChange(of: toasts.current) { _, toast in
                if let toast {
                    AccessibilityNotification.Announcement(toast.text).post()
                }
            }
    }
}

extension View {
    /// Shows the toasts of `toasts` at the bottom of this view.
    func toastOverlay(_ toasts: ToastCenter) -> some View {
        modifier(ToastOverlay(toasts: toasts))
    }
}

// MARK: - Dialogs

private struct DialogPresenter: ViewModifier {
    @Bindable var dialogs: DialogCoordinator

    /// The alert reports its dismissal here. A button may still be about to
    /// answer, so only a prompt that stays unanswered is cancelled.
    private func presented(_ isPresented: Bool, promptID: UUID?) -> Binding<Bool> {
        let dialogs = dialogs
        return Binding(
            get: { isPresented },
            set: { shown in
                guard !shown, let promptID else { return }
                Task { @MainActor in dialogs.cancel(promptID: promptID) }
            })
    }

    func body(content: Content) -> some View {
        content
            .alert(
                dialogs.confirmation?.title ?? "",
                isPresented: presented(dialogs.isConfirming, promptID: dialogs.confirmation?.id),
                presenting: dialogs.confirmation
            ) { prompt in
                Button("Abbrechen", role: .cancel) { dialogs.answerConfirmation(false) }
                Button(prompt.confirmLabel, role: prompt.isDestructive ? .destructive : nil) {
                    dialogs.answerConfirmation(true)
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .alert(
                dialogs.textPrompt?.title ?? "",
                isPresented: presented(dialogs.isRequestingText, promptID: dialogs.textPrompt?.id),
                presenting: dialogs.textPrompt
            ) { prompt in
                TextField(prompt.placeholder, text: $dialogs.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Abbrechen", role: .cancel) { dialogs.answerText(nil) }
                Button(prompt.confirmLabel) { dialogs.answerText(dialogs.text) }
            } message: { prompt in
                Text(prompt.message)
            }
    }
}

extension View {
    /// Presents the prompts of `dialogs` as alerts.
    func dialogs(_ dialogs: DialogCoordinator) -> some View {
        modifier(DialogPresenter(dialogs: dialogs))
    }
}

// MARK: - Placeholders

/// Full-size message with a retry button, for content that failed to load.
struct ErrorMessage: View {
    let text: String
    let retry: @MainActor () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Fehler", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        } actions: {
            Button("Erneut versuchen") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
        }
    }
}
