import SwiftUI

@main
struct KiboWatchApp: App {
    var body: some Scene { WindowGroup { WatchProjectsView() } }
}

@MainActor
final class WatchStore: ObservableObject {
    @Published var projects: [KiboProject] = []
    @Published var conversations: [KiboConversation] = []
    @Published var selectedID: String?
    @Published var status = "Connecting…"
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private var api: KiboAPI
    private var selectionVersion = 0
    private var loadVersion = 0
    var serverURL: String {
        let raw = defaults.string(forKey: "watchServerURL") ?? "https://wideboi.stingray-nominal.ts.net/"
        return KiboAPI.canonicalServerURL(raw) ?? "https://wideboi.stingray-nominal.ts.net/"
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "watchServerURL") ?? "https://wideboi.stingray-nominal.ts.net/"
        api = try! KiboAPI(serverURL: KiboAPI.canonicalServerURL(raw) ?? "https://wideboi.stingray-nominal.ts.net/")
        selectedID = defaults.string(forKey: "watchSelectedProjectID")
    }

    func load() async {
        loadVersion += 1
        let version = loadVersion
        do {
            let loaded = try await api.projects()
            guard version == loadVersion else { return }
            projects = loaded
            let selected = ProjectSelection.preferred(in: projects, savedID: selectedID)
            guard await select(selected?.id) else { return }
            status = "Live"
            errorMessage = nil
        } catch { status = "Offline"; errorMessage = error.localizedDescription }
    }

    @discardableResult
    func select(_ id: String?) async -> Bool {
        selectionVersion += 1
        let version = selectionVersion
        selectedID = id
        conversations = []
        if let id { defaults.set(id, forKey: "watchSelectedProjectID") }
        guard let id else { return true }
        do {
            let loaded = try await api.conversations(projectID: id)
            guard version == selectionVersion, selectedID == id else { return false }
            conversations = loaded
            status = "Live"
            errorMessage = nil
            return true
        } catch {
            guard version == selectionVersion else { return false }
            status = "Offline"
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveServer(_ value: String) async -> Bool {
        do {
            guard let canonicalURL = KiboAPI.canonicalServerURL(value) else { throw APIError.invalidServerURL }
            try await api.setServerURL(canonicalURL)
            defaults.set(canonicalURL, forKey: "watchServerURL")
            loadVersion += 1
            selectionVersion += 1
            await load()
            return errorMessage == nil
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

struct WatchProjectsView: View {
    @StateObject private var store = WatchStore()
    @State private var showingServer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.projects) { project in
                        Button {
                            Task { await store.select(project.id) }
                        } label: {
                            HStack {
                                Image(systemName: project.id == store.selectedID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(project.id == store.selectedID ? .orange : .secondary)
                                Text(project.name).lineLimit(2)
                            }
                        }
                    }
                } header: { Text("Current project") }
                if !store.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(store.conversations.prefix(5)) { conversation in
                            Label(conversation.name, systemImage: "bubble.left")
                                .font(.caption)
                        }
                    }
                }
                Section {
                    Label(store.status, systemImage: store.status == "Live" ? "checkmark.circle" : "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Kibo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Server", systemImage: "gearshape") { showingServer = true }
                }
            }
            .refreshable { await store.load() }
            .task { await store.load() }
            .sheet(isPresented: $showingServer) { WatchServerView(store: store) }
            .alert("Kibo", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) { Button("OK") { store.errorMessage = nil } }
            message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }
}

struct WatchServerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WatchStore
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $value)
                    .textInputAutocapitalization(.never)
                Button("Connect") {
                    Task { if await store.saveServer(value) { dismiss() } }
                }
            }
            .navigationTitle("Server")
            .onAppear { value = store.serverURL }
        }
    }
}
