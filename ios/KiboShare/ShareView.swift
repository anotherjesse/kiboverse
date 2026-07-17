import SwiftUI

/// The extension's whole UI: confirm (or change) the destination, save, done.
/// Intake-only by design — no compose field, no upload progress, because the
/// extension never talks to the network. The saved copy is honest about the
/// handoff: uploads happen when the app next opens.
struct ShareView: View {
    @ObservedObject var model: ShareIntakeModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Kibo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("share-cancel")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case let .unavailable(message):
            notice(symbol: "iphone.and.arrow.forward", message: message)
        case .ready:
            form
        case let .saving(completed, total):
            VStack(spacing: 12) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .padding(.horizontal, 32)
                Text("Saving \(min(completed + 1, total)) of \(total)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .saved(count, total):
            VStack(spacing: 12) {
                Image(systemName: count == total
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(count == total ? .green : .orange)
                Text(count == total
                    ? "Saved to Kibo — sends when you open Kibo."
                    : "Saved \(count) of \(total) to Kibo — sends when you open Kibo. "
                        + "\(total - count) could not be saved.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("share-saved-message")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            notice(symbol: "exclamationmark.triangle", message: message)
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Send to", selection: $model.destination) {
                    ForEach(model.destinations) { destination in
                        Text("\(destination.conversationName) · \(destination.projectName)")
                            .tag(Optional(destination))
                    }
                }
                .accessibilityIdentifier("share-destination")
            } footer: {
                Text(
                    model.imageCount == 1
                        ? "1 image will be saved and sent when you open Kibo."
                        : "\(model.imageCount) images will be saved and sent when you open Kibo."
                )
            }
            Section {
                Button {
                    model.save()
                } label: {
                    Text("Save to Kibo")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(model.destination == nil)
                .accessibilityIdentifier("share-save")
            }
        }
    }

    private func notice(symbol: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Done") { model.cancel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
