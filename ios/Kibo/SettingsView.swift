import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var value = ""
    @State private var saving = false
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Kibo server") {
                    TextField("http://kibo.local:3000", text: $value)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Text("Use 127.0.0.1:3000 in the simulator, or your trusted LAN/tailnet address on a device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.pendingUploadCount > 0 {
                    Section("Saved recordings") {
                        Label(
                            "\(store.pendingUploadCount) waiting to upload",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        Button("Retry now") { Task { _ = await store.retryPendingUploads() } }
                            .disabled(store.isUploading)
                        Button("Discard saved recordings", role: .destructive) {
                            confirmingDiscard = true
                        }
                        .disabled(store.isUploading)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await store.updateServerURL(value) { dismiss() }
                            saving = false
                        }
                    }.disabled(value.isEmpty || saving || store.isUploading || store.isSubmitting)
                }
            }
            .onAppear { value = store.serverURL }
            .alert("Discard saved recordings?", isPresented: $confirmingDiscard) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) { store.discardPendingUploads() }
            } message: {
                Text("Recordings that have not reached the server will be permanently deleted.")
            }
        }
    }
}
