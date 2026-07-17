import SwiftUI

@main
struct KiboApp: App {
    @StateObject private var store: AppStore
    @StateObject private var audio: AudioCoordinator

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _audio = StateObject(wrappedValue: AudioCoordinator(
            recordingInventoryDidChange: { [weak store] in
                store?.refreshRecordingInventory()
            }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(audio)
                .environmentObject(KiboRouter.shared)
                .tint(.kiboCoral)
                .task { await store.start() }
        }
    }
}
