import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photo Library intake via PHPicker: runs out of process, so it needs no
/// permission prompt and no Info.plist key. Delivers raw source bytes; the
/// store normalizes (strip metadata, downscale, transcode) before spooling.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    /// Called exactly once, BEFORE the picker dismisses, when the user
    /// confirmed a non-empty selection. Returns the batch that receives
    /// every picked image (nil aborts intake). Registering the gate before
    /// dismissal means no Ask can ever observe a moment where part of the
    /// selection is spooled and the rest is still loading.
    let beginIntake: @MainActor () -> ImageIntakeBatch?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 10
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let providers = results.map(\.itemProvider)
            // The batch gate must exist before the picker dismisses: from
            // this instant an Ask or server change waits for the WHOLE
            // selection, and the destination + intake timestamp are fixed.
            let batch = providers.isEmpty ? nil : parent.beginIntake()
            parent.dismiss()
            guard let batch else { return }
            // Genuinely serial: load one payload, spool it, and only load
            // the next after the last one finished — no accumulation
            // anywhere in the chain. `finish()` always runs, releasing the
            // gate even when every provider fails to load.
            Task { @MainActor in
                for provider in providers {
                    guard let data = await Self.loadImageData(from: provider) else { continue }
                    await batch.add(data)
                }
                batch.finish()
            }
        }

        private static func loadImageData(from provider: NSItemProvider) async -> Data? {
            let identifier = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
            return await withCheckedContinuation { continuation in
                // The file representation is a temp URL valid only inside this
                // completion — copy the bytes out before returning.
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
                }
            }
        }
    }
}

/// Camera intake via UIImagePickerController — zero session-management code
/// next to Kibo's already-complex audio choreography. The captured frame is
/// re-encoded by the shared normalizer, which is the single privacy chokepoint.
struct CameraCapture: UIViewControllerRepresentable {
    let onCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCapture

        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.dismiss()
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.95) else { return }
            parent.onCaptured(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
