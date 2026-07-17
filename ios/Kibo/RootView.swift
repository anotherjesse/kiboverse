import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: KiboRouter
    @State private var openConversationID: String?

    var body: some View {
        NavigationSplitView {
            ConversationListView(openConversationID: $openConversationID)
        } detail: {
            if openConversationID != nil && store.selectedConversationID != nil {
                ConversationDetailView()
            } else {
                ContentUnavailableView(
                    "Choose a conversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
        .fullScreenCover(isPresented: $router.isTalkModePresented) { TalkModeView() }
        // While talk mode is up its status line owns error display; a modal
        // here could not present over the cover anyway (the hosting
        // controller is already presenting) and would pop up stale later.
        .alert("Kibo", isPresented: Binding(
            get: { store.errorMessage != nil && !router.isTalkModePresented },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("OK") { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "Unknown error") }
        .onAppear {
            updateIdleTimer(for: scenePhase)
            openTalkModeIfRequested()
        }
        .onChange(of: scenePhase) { _, phase in updateIdleTimer(for: phase) }
        .onChange(of: router.talkModeRequestedAt) { _, _ in openTalkModeIfRequested() }
        .onChange(of: store.selectedConversationID) { _, _ in openTalkModeIfRequested() }
        .onChange(of: store.hasRestoredSelection) { _, _ in openTalkModeIfRequested() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// TalkToKiboIntent latches a request that is honored once the store has
    /// finished restoring its selection — opening the cover before
    /// `selectProject` settles would let the startup selection reset abort a
    /// hold that had already begun.
    private func openTalkModeIfRequested() {
        guard store.hasRestoredSelection, store.selectedConversationID != nil else { return }
        guard router.consumeTalkModeRequest() else { return }
        router.isTalkModePresented = true
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }
}
