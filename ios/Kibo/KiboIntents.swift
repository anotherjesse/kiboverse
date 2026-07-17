import AppIntents

/// Opens Kibo ready to push-to-talk. Exposed as an App Shortcut so it shows
/// up in Settings > Action Button > Shortcut without any manual setup in the
/// Shortcuts app.
struct OpenKiboIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Kibo"
    static let description = IntentDescription("Opens Kibo ready to talk.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Opens Kibo straight into full-screen push-to-talk for the last-selected
/// conversation. The request is latched on KiboRouter and honored by
/// RootView once the store has restored its selection.
struct TalkToKiboIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Kibo"
    static let description = IntentDescription(
        "Opens Kibo straight into push-to-talk for your last conversation."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        KiboRouter.shared.requestTalkMode()
        return .result()
    }
}

struct KiboAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKiboIntent(),
            phrases: [
                "Open \(.applicationName)"
            ],
            shortTitle: "Open Kibo",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: TalkToKiboIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start talking to \(.applicationName)"
            ],
            shortTitle: "Talk to Kibo",
            systemImageName: "waveform"
        )
    }
}
