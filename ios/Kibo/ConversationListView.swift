import SwiftUI

/// The home screen: pick a conversation, then talk into it. The project
/// switcher is the header anchor of the Projects > Conversations model — an
/// inline navigation-bar menu (folder + name + chevron) that visually affords
/// a tap. Connection state only appears when the app is not live.
struct ConversationListView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: KiboRouter
    @Binding var openConversationID: String?
    @State private var showingNewProject = false
    @State private var showingNewConversation = false
    @State private var name = ""

    var body: some View {
        List(selection: selectionBinding) {
            if store.status != "Live" {
                statusRow
            }
            Section {
                ForEach(store.conversations) { conversation in
                    NavigationLink(value: conversation.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.name)
                            Text(lastActivityLabel(conversation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if store.conversations.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a conversation to start talking to Kibo.")
                )
            }
        }
        .navigationTitle(store.selectedProject?.name ?? "Kibo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { router.isSettingsPresented = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settings-button")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New conversation", systemImage: "plus.bubble") {
                    name = ""
                    showingNewConversation = true
                }
                .disabled(store.selectedProjectID == nil)
                .accessibilityIdentifier("new-conversation-button")
                projectMenu
            }
        }
        .sheet(isPresented: $router.isSettingsPresented) { SettingsView() }
        .alert("New project", isPresented: $showingNewProject) {
            TextField("Project name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.createProject(name: name) } }
        }
        .alert("New conversation", isPresented: $showingNewConversation) {
            TextField("Optional name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task {
                    // Only navigate when creation actually selected the new
                    // conversation; on failure the previous selection is
                    // unchanged and the error alert is the only signal.
                    let previous = store.selectedConversationID
                    await store.createConversation(name: name.isEmpty ? nil : name)
                    if let created = store.selectedConversationID, created != previous {
                        openConversationID = created
                    }
                }
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { openConversationID },
            set: { id in
                openConversationID = id
                if let id, id != store.selectedConversationID {
                    Task { await store.selectConversation(id) }
                }
            }
        )
    }

    /// Projects > Conversations: the title names the current project and this
    /// folder menu in the upper right switches it. A secondary treatment —
    /// switching projects is rarer than starting a conversation.
    private var projectMenu: some View {
        Menu {
            ForEach(store.projects) { project in
                Button {
                    openConversationID = nil
                    Task { await store.selectProject(project.id) }
                } label: {
                    if project.id == store.selectedProjectID {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("New project…", systemImage: "folder.badge.plus") {
                name = ""
                showingNewProject = true
            }
        } label: {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Project: \(store.selectedProject?.name ?? "none")")
        .accessibilityIdentifier("project-menu")
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.kiboCoral).frame(width: 7, height: 7)
            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .listRowBackground(Color.clear)
        .selectionDisabled()
    }

    private func lastActivityLabel(_ conversation: KiboConversation) -> String {
        let activity = conversation.last_activity_at ?? 0
        let timestamp = max(activity, conversation.created_at)
        guard timestamp > 0 else { return "New" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return date.formatted(.relative(presentation: .named))
    }
}
