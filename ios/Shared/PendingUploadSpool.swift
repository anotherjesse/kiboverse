import CryptoKit
import Foundation

struct LocalRecording: Sendable {
    let id: String
    let url: URL
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
}

/// Process-local ownership for recorder scratch files. Scratch filenames are
/// unique, so a relaunch never overwrites an interrupted capture; a live lease
/// keeps the spool scanner from presenting the recorder's open file as a crash
/// recovery item. If the process dies, the lease disappears and the next scan
/// exposes the file for explicit recovery.
final class ActiveRecordingFileLease: @unchecked Sendable {
    private enum LeaseError: Error {
        case released
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var paths = Set<String>()
    }

    private static let registry = Registry()

    let url: URL
    private let stateLock = NSLock()
    private var released = false

    init(url: URL) {
        self.url = url.standardizedFileURL
        Self.registry.lock.withLock {
            _ = Self.registry.paths.insert(self.url.path)
        }
    }

    func markStarted() throws {
        guard stateLock.withLock({ !released }) else { throw LeaseError.released }
        try Data().write(to: Self.startedMarkerURL(for: url), options: .atomic)
    }

    func relinquish() {
        releaseRegistryEntry()
        try? FileManager.default.removeItem(at: Self.startedMarkerURL(for: url))
    }

    /// Release process ownership while retaining the durable evidence that
    /// capture began. The next inventory scan will surface the WAV for an
    /// explicit recovery decision instead of treating it as recorder prewarm.
    func abandonForRecovery() {
        releaseRegistryEntry()
    }

    private func releaseRegistryEntry() {
        let shouldRemove = stateLock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRemove else { return }
        _ = Self.registry.lock.withLock {
            Self.registry.paths.remove(url.path)
        }
    }

    deinit {
        // Leave a started marker behind if ownership vanishes unexpectedly.
        // A normal stop/cancel calls relinquish() and removes it explicitly.
        releaseRegistryEntry()
    }

    static func isActive(_ url: URL) -> Bool {
        registry.lock.withLock {
            registry.paths.contains(url.standardizedFileURL.path)
        }
    }

    static func startedMarkerURL(for url: URL) -> URL {
        url.appendingPathExtension("started")
    }
}

struct PendingClip: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: String
    let serverURL: String
    let projectID: String
    let conversationID: String
    let wavFilename: String
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
    let enqueuedAtMs: Int64
    let sha256: String?
    let recoveryReason: String?
    let recoveryDetail: String?

    var destinationKey: String { "\(projectID)/\(conversationID)" }

    init(
        id: String,
        serverURL: String,
        projectID: String,
        conversationID: String,
        wavFilename: String,
        durationMs: Int,
        peakPct: Int,
        recordedAt: Int,
        enqueuedAtMs: Int64,
        sha256: String?,
        recoveryReason: String? = nil,
        recoveryDetail: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.serverURL = serverURL
        self.projectID = projectID
        self.conversationID = conversationID
        self.wavFilename = wavFilename
        self.durationMs = durationMs
        self.peakPct = peakPct
        self.recordedAt = recordedAt
        self.enqueuedAtMs = enqueuedAtMs
        self.sha256 = sha256
        self.recoveryReason = recoveryReason
        self.recoveryDetail = recoveryDetail
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case serverURL
        case projectID
        case conversationID
        case wavFilename
        case durationMs
        case peakPct
        case recordedAt
        case enqueuedAtMs
        case sha256
        case recoveryReason
        case recoveryDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported pending-recording schema version \(version)"
            )
        }
        schemaVersion = version
        id = try container.decode(String.self, forKey: .id)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        projectID = try container.decode(String.self, forKey: .projectID)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        wavFilename = try container.decode(String.self, forKey: .wavFilename)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        peakPct = try container.decodeIfPresent(Int.self, forKey: .peakPct) ?? 0
        recordedAt = try container.decodeIfPresent(Int.self, forKey: .recordedAt) ?? 0
        if let persisted = try container.decodeIfPresent(Int64.self, forKey: .enqueuedAtMs) {
            enqueuedAtMs = persisted
        } else {
            guard let seconds = Int64(exactly: recordedAt) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .recordedAt,
                    in: container,
                    debugDescription: "The legacy recording timestamp is out of range"
                )
            }
            let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
            guard !overflow else {
                throw DecodingError.dataCorruptedError(
                    forKey: .recordedAt,
                    in: container,
                    debugDescription: "The legacy recording timestamp is out of range"
                )
            }
            enqueuedAtMs = milliseconds
        }
        if version >= 2 {
            let digest = try container.decode(String.self, forKey: .sha256)
            guard SpoolPrimitives.isLowercaseHexSHA256(digest) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sha256,
                    in: container,
                    debugDescription: "Version-2 pending recordings require a lowercase SHA-256 digest"
                )
            }
            sha256 = digest
        } else {
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        }
        recoveryReason = try container.decodeIfPresent(String.self, forKey: .recoveryReason)
        recoveryDetail = try container.decodeIfPresent(String.self, forKey: .recoveryDetail)
    }
}

struct RecordingRecoveryItem: Identifiable, Equatable, Sendable {
    enum Reason: String, Hashable, Sendable {
        case interruptedWorkingFile
        case missingMetadata
        case unreadableMetadata
        case metadataIdentityMismatch
        case metadataWithoutAudio
        case unsafeAudioPath
        case audioChecksumMismatch
        case unreadableDirectory
    }

    let id: String
    let reason: Reason
    let audioURL: URL?
    let metadataURL: URL?
    let detail: String
    let markerURL: URL?

    init(
        id: String,
        reason: Reason,
        audioURL: URL?,
        metadataURL: URL?,
        detail: String,
        markerURL: URL? = nil
    ) {
        self.id = id
        self.reason = reason
        self.audioURL = audioURL
        self.metadataURL = metadataURL
        self.detail = detail
        self.markerURL = markerURL
    }
}

struct PendingUploadInventory: Sendable {
    let clips: [PendingClip]
    let recoveryItems: [RecordingRecoveryItem]

    func protectedCount(for serverURL: String) -> Int {
        clips.lazy.filter { $0.serverURL == serverURL }.count + recoveryItems.count
    }
}

struct PendingUploadSpool {
    static let phoneDirectoryName = "PendingRecordings"
    static let watchDirectoryName = "WatchPendingRecordings"

    private let fileManager: FileManager
    private let directoryURL: URL

    init(directoryName: String, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            directoryURL: base.appendingPathComponent(directoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func enqueue(
        recording: LocalRecording,
        serverURL: String,
        projectID: String,
        conversationID: String
    ) throws -> PendingClip {
        try ensureDirectory()
        let bytes = try Data(contentsOf: recording.url)
        let clip = PendingClip(
            id: recording.id,
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID,
            wavFilename: recording.url.lastPathComponent,
            durationMs: recording.durationMs,
            peakPct: recording.peakPct,
            recordedAt: recording.recordedAt,
            enqueuedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            sha256: Self.sha256(bytes)
        )
        try JSONEncoder().encode(clip).write(to: metadataURL(for: clip.id), options: .atomic)
        return clip
    }

    func inventory() -> PendingUploadInventory {
        do {
            try ensureDirectory()
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            return inventory(files: files)
        } catch {
            return PendingUploadInventory(
                clips: [],
                recoveryItems: [
                    RecordingRecoveryItem(
                        id: "unreadable-directory",
                        reason: .unreadableDirectory,
                        audioURL: nil,
                        metadataURL: nil,
                        detail: error.localizedDescription
                    )
                ]
            )
        }
    }

    func all() -> [PendingClip] {
        inventory().clips
    }

    func wavURL(for clip: PendingClip) -> URL {
        directoryURL.appendingPathComponent(clip.wavFilename)
    }

    func quarantine(
        _ clip: PendingClip,
        reason: RecordingRecoveryItem.Reason,
        detail: String
    ) throws {
        let quarantined = PendingClip(
            id: clip.id,
            serverURL: clip.serverURL,
            projectID: clip.projectID,
            conversationID: clip.conversationID,
            wavFilename: clip.wavFilename,
            durationMs: clip.durationMs,
            peakPct: clip.peakPct,
            recordedAt: clip.recordedAt,
            enqueuedAtMs: clip.enqueuedAtMs,
            sha256: clip.sha256,
            recoveryReason: reason.rawValue,
            recoveryDetail: detail
        )
        try JSONEncoder().encode(quarantined).write(
            to: metadataURL(for: clip.id),
            options: .atomic
        )
    }

    func remove(_ clip: PendingClip) {
        try? fileManager.removeItem(at: metadataURL(for: clip.id))
        try? fileManager.removeItem(at: wavURL(for: clip))
    }

    func remove(_ recovery: RecordingRecoveryItem) throws {
        if recovery.reason == .unreadableDirectory {
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
            try ensureDirectory()
            return
        }
        if let metadataURL = recovery.metadataURL {
            try removeIfPresent(metadataURL)
        }
        if let audioURL = recovery.audioURL {
            try removeIfPresent(audioURL)
        }
        if let markerURL = recovery.markerURL {
            try removeIfPresent(markerURL)
        }
    }

    private func inventory(files: [URL]) -> PendingUploadInventory {
        let metadataFiles = files.filter { $0.pathExtension == "json" }
        let audioFiles = files.filter { $0.pathExtension.lowercased() == "wav" }
        var clips: [PendingClip] = []
        var recoveryItems: [RecordingRecoveryItem] = []
        var accountedAudioPaths = Set<String>()

        for metadataURL in metadataFiles {
            let sidecarID = metadataURL.deletingPathExtension().lastPathComponent
            let clip: PendingClip
            do {
                let data = try Data(contentsOf: metadataURL)
                clip = try JSONDecoder().decode(PendingClip.self, from: data)
            } catch {
                let guessedAudio = directoryURL.appendingPathComponent("recording-\(sidecarID).wav")
                let existingAudio = fileManager.fileExists(atPath: guessedAudio.path)
                    ? guessedAudio
                    : nil
                if let existingAudio {
                    accountedAudioPaths.insert(existingAudio.standardizedFileURL.path)
                }
                recoveryItems.append(RecordingRecoveryItem(
                    id: "metadata-\(sidecarID)",
                    reason: .unreadableMetadata,
                    audioURL: existingAudio,
                    metadataURL: metadataURL,
                    detail: error.localizedDescription
                ))
                continue
            }

            guard clip.id == sidecarID else {
                recoveryItems.append(RecordingRecoveryItem(
                    id: "identity-\(sidecarID)",
                    reason: .metadataIdentityMismatch,
                    audioURL: nil,
                    metadataURL: metadataURL,
                    detail: "The metadata filename and recording ID do not match."
                ))
                continue
            }

            guard Self.isSafeFilename(clip.wavFilename) else {
                recoveryItems.append(RecordingRecoveryItem(
                    id: "unsafe-\(sidecarID)",
                    reason: .unsafeAudioPath,
                    audioURL: nil,
                    metadataURL: metadataURL,
                    detail: "The metadata contains an unsafe audio filename."
                ))
                continue
            }

            let audioURL = wavURL(for: clip)
            let audioPath = audioURL.standardizedFileURL.path
            accountedAudioPaths.insert(audioPath)
            guard fileManager.fileExists(atPath: audioPath) else {
                recoveryItems.append(RecordingRecoveryItem(
                    id: "missing-audio-\(sidecarID)",
                    reason: .metadataWithoutAudio,
                    audioURL: nil,
                    metadataURL: metadataURL,
                    detail: "The recording metadata exists, but its WAV file is missing."
                ))
                continue
            }
            if let rawReason = clip.recoveryReason {
                let reason = RecordingRecoveryItem.Reason(rawValue: rawReason)
                    ?? .unreadableMetadata
                recoveryItems.append(RecordingRecoveryItem(
                    id: "quarantined-\(sidecarID)",
                    reason: reason,
                    audioURL: audioURL,
                    metadataURL: metadataURL,
                    detail: clip.recoveryDetail ?? "The recording requires manual recovery."
                ))
                continue
            }
            clips.append(clip)
        }

        for audioURL in audioFiles {
            let path = audioURL.standardizedFileURL.path
            guard !accountedAudioPaths.contains(path),
                  !ActiveRecordingFileLease.isActive(audioURL) else { continue }
            let versionedScratch = Self.isVersionedScratchFilename(audioURL.lastPathComponent)
            let legacyScratch = audioURL.lastPathComponent == "working-recording.wav"
            let markerURL = ActiveRecordingFileLease.startedMarkerURL(for: audioURL)
            let wasStarted = fileManager.fileExists(atPath: markerURL.path)
            if versionedScratch && !wasStarted {
                // AVAudioRecorder creates a small WAV during prepareToRecord().
                // Without the durable started marker this file never contained
                // a user capture and is safe to clean after its live lease ends.
                try? fileManager.removeItem(at: audioURL)
                continue
            }
            let working = legacyScratch || (versionedScratch && wasStarted)
            recoveryItems.append(RecordingRecoveryItem(
                id: "audio-\(audioURL.deletingPathExtension().lastPathComponent)",
                reason: working ? .interruptedWorkingFile : .missingMetadata,
                audioURL: audioURL,
                metadataURL: nil,
                detail: working
                    ? "Recording was interrupted before it could be finalized."
                    : "Recording audio exists without upload metadata.",
                markerURL: wasStarted ? markerURL : nil
            ))
        }

        clips.sort { ($0.enqueuedAtMs, $0.id) < ($1.enqueuedAtMs, $1.id) }
        recoveryItems.sort { $0.id < $1.id }
        return PendingUploadInventory(clips: clips, recoveryItems: recoveryItems)
    }

    private func metadataURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        SpoolPrimitives.isSafeFilename(filename)
    }

    private static func isVersionedScratchFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".wav") else { return false }
        let stem = String(filename.dropLast(4))
        let prefix = "working-recording-"
        guard stem.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SpoolPrimitives.sha256Hex(data)
    }
}
