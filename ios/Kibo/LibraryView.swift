import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @State private var showingNewProject = false
    @State private var showingNewConversation = false
    @State private var name = ""

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { store.selectedProjectID },
                set: { value in Task { await store.selectProject(value) } }
            )) {
                Section("Projects") {
                    ForEach(store.projects) { project in
                        NavigationLink(value: project.id) {
                            Label(project.name, systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("Kibo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New project", systemImage: "folder.badge.plus") {
                        name = ""; showingNewProject = true
                    }
                }
            }
        } content: {
            List(selection: Binding(
                get: { store.selectedConversationID },
                set: { value in Task { await store.selectConversation(value) } }
            )) {
                ForEach(store.conversations) { conversation in
                    NavigationLink(value: conversation.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.name)
                            Text(conversation.name_source?.rawValue ?? "conversation")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(store.selectedProject?.name ?? "Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New conversation", systemImage: "plus.bubble") {
                        name = ""; showingNewConversation = true
                    }
                    .disabled(store.selectedProjectID == nil)
                }
            }
        } detail: {
            ConversationDetailView()
        }
        .alert("New project", isPresented: $showingNewProject) {
            TextField("Project name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.createProject(name: name) } }
        }
        .alert("New conversation", isPresented: $showingNewConversation) {
            TextField("Optional name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.createConversation(name: name.isEmpty ? nil : name) } }
        }
    }
}
