import Foundation
import UniformTypeIdentifiers

/// The share extension is an **intake, not an uploader**: it normalizes each
/// shared image (serially — one decode in memory at a time, bounded by
/// `ImageNormalizer`'s thumbnail path) and enqueues it into the shared spool
/// with a destination from the app-written cache. No network, no sweeping, no
/// GC — the main app is the sole uploader and the sole owner of maintenance.
@MainActor
final class ShareIntakeModel: ObservableObject {
    /// The phase VALUES and their reducers live in Shared (`ShareIntakePhase`
    /// / `ShareIntake`) so they are unit-testable from the main app's test
    /// bundle; this model only sequences them.
    typealias Phase = ShareIntakePhase

    @Published private(set) var phase: Phase
    @Published var destination: DestinationCache.Destination?
    let destinations: [DestinationCache.Destination]
    let imageCount: Int

    private let spool: PendingAttachmentSpool?
    private let imageProviders: [NSItemProvider]
    private let textProviders: [NSItemProvider]
    private let attributedText: String?
    private let onComplete: () -> Void
    private let onCancel: () -> Void

    init(
        inputItems: [NSExtensionItem],
        spool: PendingAttachmentSpool?,
        cache: DestinationCache?,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.spool = spool
        self.onComplete = onComplete
        self.onCancel = onCancel

        let providers = inputItems.flatMap { $0.attachments ?? [] }
        imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        // Share-sheet text that accompanies the images (never an image itself)
        // becomes the caption of the first spooled image.
        textProviders = providers.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                && $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        attributedText = inputItems.lazy
            .compactMap { $0.attributedContentText?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        imageCount = imageProviders.count
        destinations = cache?.allDestinations ?? []
        let resolvedDefault = cache?.defaultDestination
        destination = resolvedDefault

        phase = ShareIntake.initialPhase(
            spoolAvailable: spool != nil,
            hasDefaultDestination: resolvedDefault != nil,
            imageCount: imageProviders.count
        )
    }

    var isBusy: Bool {
        if case .saving = phase { return true }
        return false
    }

    func save() {
        guard case .ready = phase, let spool, let destination else { return }
        phase = .saving(completed: 0, total: imageCount)
        Task { await performSave(spool: spool, destination: destination) }
    }

    func cancel() {
        onCancel()
    }

    func finish() {
        onComplete()
    }

    private func performSave(
        spool: PendingAttachmentSpool, destination: DestinationCache.Destination
    ) async {
        let sharedText = await resolveSharedText()
        var spooled = 0
        for provider in imageProviders {
            guard let data = await ShareItemLoader.imageData(from: provider) else { continue }
            do {
                let normalized = try await Task.detached(priority: .userInitiated) {
                    try ImageNormalizer.normalize(data: data)
                }.value
                _ = try spool.enqueue(
                    image: normalized,
                    serverURL: destination.serverURL,
                    projectID: destination.projectID,
                    conversationID: destination.conversationID,
                    caption: ShareIntake.caption(
                        forSpooledImageAt: spooled, sharedText: sharedText
                    ),
                    source: "share"
                )
                spooled += 1
                phase = .saving(completed: spooled, total: imageCount)
            } catch {
                continue
            }
        }
        let completion = ShareIntake.completionPhase(spooled: spooled, total: imageCount)
        phase = completion
        guard case let .saved(count, total) = completion else { return }
        try? await Task.sleep(for: .seconds(count == total ? 1.4 : 3.0))
        onComplete()
    }

    private func resolveSharedText() async -> String? {
        if let attributedText { return attributedText }
        guard let provider = textProviders.first else { return nil }
        return await ShareItemLoader.plainText(from: provider)
    }
}

/// Loads one provider's bytes at a time. Prefers the file representation
/// (the provider streams to disk; we read once) and falls back to the data
/// representation for providers that only vend in-memory objects.
enum ShareItemLoader {
    static func imageData(from provider: NSItemProvider) async -> Data? {
        if let data = await fileRepresentationData(from: provider) { return data }
        return await dataRepresentation(
            from: provider, typeIdentifier: UTType.image.identifier
        )
    }

    static func plainText(from provider: NSItemProvider) async -> String? {
        let data = await dataRepresentation(
            from: provider, typeIdentifier: UTType.plainText.identifier
        )
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func fileRepresentationData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { url, _ in
                // The provider deletes the file when this handler returns, so
                // the bytes must be fully read (never mapped) before resuming.
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }
    }

    private static func dataRepresentation(
        from provider: NSItemProvider, typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
