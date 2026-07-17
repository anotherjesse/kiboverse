import SwiftUI

/// Cross-cutting navigation state: App Intents run before the store has
/// restored the last-selected conversation, so a talk-mode request is latched
/// here and consumed by RootView once selection restore has settled.
@MainActor
final class KiboRouter: ObservableObject {
    static let shared = KiboRouter()

    /// How long a `TalkToKiboIntent` request stays honorable. Without an
    /// expiry, a request latched when nothing was selectable (fresh install,
    /// server down) would throw the user into full-screen talk mode hours
    /// later when they finally tap a conversation.
    private static let requestLifetime: TimeInterval = 30

    /// Latched request from `TalkToKiboIntent`; RootView consumes it.
    @Published private(set) var talkModeRequestedAt: Date?
    /// Whether the full-screen push-to-talk cover is up.
    @Published var isTalkModePresented = false
    /// Whether the Settings sheet is up — shared so the detail view's reply
    /// autoplay gate can treat it as an overlay (matters on iPad, where both
    /// columns stay visible under the sheet).
    @Published var isSettingsPresented = false

    func requestTalkMode() {
        talkModeRequestedAt = Date()
    }

    /// Clears the latch and reports whether the request is recent enough to
    /// honor with a full-screen presentation.
    func consumeTalkModeRequest() -> Bool {
        guard let requestedAt = talkModeRequestedAt else { return false }
        talkModeRequestedAt = nil
        return Date().timeIntervalSince(requestedAt) <= Self.requestLifetime
    }
}
