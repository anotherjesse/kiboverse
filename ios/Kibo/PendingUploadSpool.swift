import Foundation

struct PendingClip: Codable, Identifiable, Sendable {
    let id: String
    let serverURL: String
    let projectID: String
    let conversationID: String
    let wavFilename: String
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
    let enqueuedAtMs: Int64

    var destinationKey: String { "\(projectID)/\(conversationID)" }
}

struct PendingUploadSpool {
    private let fileManager = FileManager.default

    func enqueue(
        recording: LocalRecording, serverURL: String,
        projectID: String, conversationID: String
    ) throws -> PendingClip {
        let pending = PendingClip(
            id: recording.id, serverURL: serverURL,
            projectID: projectID, conversationID: conversationID,
            wavFilename: recording.url.lastPathComponent,
            durationMs: recording.durationMs, peakPct: recording.peakPct,
            recordedAt: recording.recordedAt,
            enqueuedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
        )
        let data = try JSONEncoder().encode(pending)
        try data.write(to: metadataURL(for: pending.id), options: .atomic)
        return pending
    }

    func all() -> [PendingClip] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { metadataURL -> PendingClip? in
                guard let data = try? Data(contentsOf: metadataURL),
                      let clip = try? JSONDecoder().decode(PendingClip.self, from: data) else {
                    return nil
                }
                guard fileManager.fileExists(atPath: wavURL(for: clip).path) else {
                    try? fileManager.removeItem(at: metadataURL)
                    return nil
                }
                return clip
            }
            .sorted {
                ($0.enqueuedAtMs, $0.id) < ($1.enqueuedAtMs, $1.id)
            }
    }

    func wavURL(for clip: PendingClip) -> URL {
        directory().appendingPathComponent(clip.wavFilename)
    }

    func remove(_ clip: PendingClip) {
        try? fileManager.removeItem(at: metadataURL(for: clip.id))
        try? fileManager.removeItem(at: wavURL(for: clip))
    }

    private func metadataURL(for id: String) -> URL {
        directory().appendingPathComponent("\(id).json")
    }

    private func directory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("PendingRecordings", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
