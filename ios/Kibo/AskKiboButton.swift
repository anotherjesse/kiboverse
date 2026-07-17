import SwiftUI

/// The one "Ask Kibo" control, shared by the conversation composer and
/// full-screen talk mode. Styled as a hug-content coral capsule — not a
/// full-width field shape — so it reads as a button, never as a text-input
/// placeholder (the app has no text input). When there is nothing to ask it
/// stays a coral button at reduced opacity instead of turning into a gray
/// compose-bar lookalike.
struct AskKiboButton: View {
    @EnvironmentObject private var store: AppStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if store.isAskingKibo {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(label)
                    .lineLimit(1)
            }
            .font(.headline)
            .foregroundStyle(.white.opacity(canAsk ? 1 : 0.85))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(Color.kiboCoral.opacity(canAsk ? 1 : 0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canAsk)
        .accessibilityIdentifier("ask-kibo-button")
    }

    private var canAsk: Bool {
        store.recoveryItemCount == 0
            && (store.askableClipCount > 0 || store.isAskingKibo)
    }

    private var label: String {
        if store.isAskingKibo { return "Asking Kibo…" }
        let count = store.askableClipCount
        return count > 0 ? "Ask Kibo · \(count)" : "Ask Kibo"
    }
}
