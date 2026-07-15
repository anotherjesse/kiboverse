import SwiftUI

@main
struct KiboApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var audio = AudioCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(audio)
                .tint(.kiboCoral)
                .task { await store.start() }
        }
    }
}

extension Color {
    static let kiboCoral = Color(red: 0.94, green: 0.34, blue: 0.29)
    static let kiboInk = Color(red: 0.10, green: 0.12, blue: 0.18)
}
