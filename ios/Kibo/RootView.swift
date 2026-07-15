import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                TalkView()
            }
            .tabItem { Label("Talk", systemImage: "mic.fill") }

            LibraryView(showingSettings: $showingSettings)
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Kibo", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("OK") { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "Unknown error") }
        .onAppear { updateIdleTimer(for: scenePhase) }
        .onChange(of: scenePhase) { _, phase in updateIdleTimer(for: phase) }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }
}
