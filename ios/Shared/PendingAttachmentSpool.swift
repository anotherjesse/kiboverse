import Foundation

/// Sidecar value for one spooled image attachment. Like `PendingClip`, it pins
/// the full destination so a spooled value can never be uploaded somewhere the
/// user did not choose when it was added.
struct PendingAttachment: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let serverURL: String
    let projectID: String
    let conversationID: String
    let filename: String
    let mime: String
    let byteCount: Int
    let width: Int
    let height: Int
    let recordedAt: Int
    let enqueuedAtMs: Int64
    let sha256: String
    let caption: String?
    let source: String
    let recoveryReason: String?
    let recoveryDetail: String?

    var destinationKey: String { "\(projectID)/\(conversationID)" }

    init(
        id: String,
        serverURL: String,
        projectID: String,
        conversationID: String,
        filename: String,
        mime: String,
        byteCount: Int,
        width: Int,
        height: Int,
        recordedAt: Int,
        enqueuedAtMs: Int64,
        sha256: String,
        caption: String?,
        source: String,
        recoveryReason: String? = nil,
        recoveryDetail: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.serverURL = serverURL
        self.projectID = projectID
        self.conversationID = conversationID
        self.filename = filename
        self.mime = mime
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.recordedAt = recordedAt
        self.enqueuedAtMs = enqueuedAtMs
        self.sha256 = sha256
        self.caption = caption
        self.source = source
        self.recoveryReason = recoveryReason
        self.recoveryDetail = recoveryDetail
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, serverURL, projectID, conversationID
        case filename, mime, byteCount, width, height, recordedAt
        case enqueuedAtMs, sha256, caption, source
        case recoveryReason, recoveryDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported pending-attachment schema version \(version)"
            )
        }
        schemaVersion = version
        id = try container.decode(String.self, forKey: .id)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        projectID = try container.decode(String.self, forKey: .projectID)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        filename = try container.decode(String.self, forKey: .filename)
        mime = try container.decode(String.self, forKey: .mime)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        recordedAt = try container.decode(Int.self, forKey: .recordedAt)
        enqueuedAtMs = try container.decode(Int64.self, forKey: .enqueuedAtMs)
        let digest = try container.decode(String.self, forKey: .sha256)
        guard SpoolPrimitives.isLowercaseHexSHA256(digest) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sha256,
                in: container,
                debugDescription: "Pending attachments require a lowercase SHA-256 digest"
            )
        }
        sha256 = digest
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        recoveryReason = try container.decodeIfPresent(String.self, forKey: .recoveryReason)
        recoveryDetail = try container.decodeIfPresent(String.self, forKey: .recoveryDetail)
    }
}

struct AttachmentRecoveryItem: Identifiable, Equatable, Sendable {
    enum Reason: String, Hashable, Sendable {
        case unreadableMetadata
        case metadataIdentityMismatch
        case unsafePayloadPath
        case metadataWithoutPayload
        case payloadChecksumMismatch
        case serverRejected
        case unreadableDirectory
    }

    let id: String
    let reason: Reason
    let packageURL: URL?
    let detail: String
}

struct PendingAttachmentInventory: Sendable {
    let attachments: [PendingAttachment]
    let recoveryItems: [AttachmentRecoveryItem]

    func protectedCount(for serverURL: String) -> Int {
        attachments.lazy.filter { $0.serverURL == serverURL }.count + recoveryItems.count
    }
}

/// Durable spool for image attachments, a deliberate sibling of
/// `PendingUploadSpool` (shared code lives in `SpoolPrimitives` only).
///
/// Crash contract: each attachment is a **package directory** (payload +
/// `attachment.json` sidecar) staged under `tmp/` with a UUID-bearing name and
/// atomically **renamed into `pending/`** — the rename is the cross-process
/// commit, so writers and scanners never observe a partial package. `tmp/`
/// garbage collection belongs solely to the main-app sweep and only touches
/// packages older than 24 h, so another process mid-stage can never lose its
/// package.
///
/// Roots: Application Support in Phase C. `migrationRootURL` is the Phase D
/// seam — every sweep also scans that root's `pending/` and drains it into
/// this root by idempotent per-package rename (same-id collision → verify sha
/// equality and drop the source; a crash mid-move leaves each package in
/// exactly one root).
struct PendingAttachmentSpool {
    static let directoryName = "PendingAttachments"
    static let sidecarFilename = "attachment.json"
    static let stagingGarbageAge: TimeInterval = 24 * 60 * 60
    static let maximumCaptionBytes = 4_096

    private let fileManager: FileManager
    private let rootURL: URL
    private let migrationRootURL: URL?

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            rootURL: base.appendingPathComponent(Self.directoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    init(rootURL: URL, migrationRootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.migrationRootURL = migrationRootURL
        self.fileManager = fileManager
        try? ensureDirectories()
    }

    private var pendingURL: URL { rootURL.appendingPathComponent("pending", isDirectory: true) }
    private var stagingURL: URL { rootURL.appendingPathComponent("tmp", isDirectory: true) }

    func enqueue(
        image: NormalizedImage,
        serverURL: String,
        projectID: String,
        conversationID: String,
        caption: String? = nil,
        source: String
    ) throws -> PendingAttachment {
        try ensureDirectories()
        let id = UUID().uuidString.lowercased()
        let filename = "image-\(id).\(image.fileExtension)"
        let attachment = PendingAttachment(
            id: id,
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID,
            filename: filename,
            mime: image.mime,
            byteCount: image.data.count,
            width: image.width,
            height: image.height,
            recordedAt: image.recordedAt,
            enqueuedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            sha256: image.sha256,
            caption: Self.boundedCaption(caption),
            source: source
        )
        let stageURL = stagingURL.appendingPathComponent(
            "stage-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
        try image.data.write(to: stageURL.appendingPathComponent(filename), options: .atomic)
        try JSONEncoder().encode(attachment).write(
            to: stageURL.appendingPathComponent(Self.sidecarFilename), options: .atomic
        )
        try fileManager.moveItem(
            at: stageURL,
            to: pendingURL.appendingPathComponent(id, isDirectory: true)
        )
        return attachment
    }

    func inventory() -> PendingAttachmentInventory {
        do {
            try ensureDirectories()
            let entries = try fileManager.contentsOfDirectory(
                at: pendingURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            return inventory(packages: entries)
        } catch {
            return PendingAttachmentInventory(
                attachments: [],
                recoveryItems: [
                    AttachmentRecoveryItem(
                        id: "unreadable-directory",
                        reason: .unreadableDirectory,
                        packageURL: nil,
                        detail: error.localizedDescription
                    )
                ]
            )
        }
    }

    func all() -> [PendingAttachment] {
        inventory().attachments
    }

    func payloadURL(for attachment: PendingAttachment) -> URL {
        pendingURL
            .appendingPathComponent(attachment.id, isDirectory: true)
            .appendingPathComponent(attachment.filename)
    }

    func quarantine(
        _ attachment: PendingAttachment,
        reason: AttachmentRecoveryItem.Reason,
        detail: String
    ) throws {
        let quarantined = PendingAttachment(
            id: attachment.id,
            serverURL: attachment.serverURL,
            projectID: attachment.projectID,
            conversationID: attachment.conversationID,
            filename: attachment.filename,
            mime: attachment.mime,
            byteCount: attachment.byteCount,
            width: attachment.width,
            height: attachment.height,
            recordedAt: attachment.recordedAt,
            enqueuedAtMs: attachment.enqueuedAtMs,
            sha256: attachment.sha256,
            caption: attachment.caption,
            source: attachment.source,
            recoveryReason: reason.rawValue,
            recoveryDetail: detail
        )
        try JSONEncoder().encode(quarantined).write(
            to: pendingURL
                .appendingPathComponent(attachment.id, isDirectory: true)
                .appendingPathComponent(Self.sidecarFilename),
            options: .atomic
        )
    }

    func remove(_ attachment: PendingAttachment) {
        try? fileManager.removeItem(
            at: pendingURL.appendingPathComponent(attachment.id, isDirectory: true)
        )
    }

    func remove(_ recovery: AttachmentRecoveryItem) throws {
        if recovery.reason == .unreadableDirectory {
            if fileManager.fileExists(atPath: pendingURL.path) {
                try fileManager.removeItem(at: pendingURL)
            }
            try ensureDirectories()
            return
        }
        if let packageURL = recovery.packageURL,
           fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
    }

    /// Launch/foreground maintenance, owned by the main app: drain committed
    /// packages from the migration root, then collect abandoned staging
    /// packages (older than 24 h) in both roots.
    func sweep(now: Date = Date()) {
        try? ensureDirectories()
        if let migrationRootURL {
            let migrationPending = migrationRootURL.appendingPathComponent(
                "pending", isDirectory: true
            )
            for packageURL in directories(in: migrationPending) {
                adopt(packageAt: packageURL)
            }
            collectStagingGarbage(
                in: migrationRootURL.appendingPathComponent("tmp", isDirectory: true),
                now: now
            )
        }
        collectStagingGarbage(in: stagingURL, now: now)
    }

    /// Idempotent per-package migration move. Re-running after any crash
    /// converges: the copy is staged in THIS root's `tmp/` (a same-volume
    /// rename is the only way anything ever enters `pending/`), the source is
    /// deleted only after the rename commits, and same-id collisions are
    /// decided on verified payload BYTES — a corrupt committed copy is
    /// replaced, a verified one absorbs its duplicate, and two verified but
    /// different payloads under one id are never destroyed.
    private func adopt(packageAt sourceURL: URL) {
        let destinationURL = pendingURL.appendingPathComponent(
            sourceURL.lastPathComponent, isDirectory: true
        )
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            adoptViaStaging(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                replacingDestination: false
            )
            return
        }
        let committedDigest = verifiedPayloadDigest(inPackage: destinationURL)
        let sourceDigest = verifiedPayloadDigest(inPackage: sourceURL)
        switch (committedDigest, sourceDigest) {
        case let (.some(committed), .some(source)) where committed == source:
            try? fileManager.removeItem(at: sourceURL)
        case (.some, .some):
            // Verified but different bytes under one id: a conflict never
            // destroys data — leave both for inspection. Practically
            // unreachable (ids are UUIDs minted at enqueue, so two roots
            // would have to mint the same UUID for different payloads);
            // retained because the cost is one stranded package, never lost
            // data.
            break
        case (.some, .none):
            // The committed copy is verified; the source duplicate is corrupt.
            try? fileManager.removeItem(at: sourceURL)
        case (.none, .some):
            // The committed copy does not hash to its own sidecar (e.g. a
            // partial cross-volume copy left by an old binary) — replace it
            // with the verified source instead of trusting it.
            adoptViaStaging(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                replacingDestination: true
            )
        case (.none, .none):
            // Neither verifies. Leave both: the committed one surfaces as a
            // recovery item; once it is discarded, the source is adopted and
            // surfaces in turn, so nothing is ever silently lost.
            break
        }
    }

    /// Cross-root package moves must preserve the invariant that `pending/`
    /// only ever gains complete packages by same-volume rename. A direct
    /// `moveItem` across volumes degrades to copy+delete, and a crash
    /// mid-copy would wedge a partial package into `pending/` forever. So:
    /// copy into this root's `tmp/` (a crash leaves only staging garbage the
    /// sweep collects), rename into `pending/`, and only then delete the
    /// source — every crash window leaves the package whole in at least one
    /// root.
    private func adoptViaStaging(
        sourceURL: URL, destinationURL: URL, replacingDestination: Bool
    ) {
        let stageURL = stagingURL.appendingPathComponent(
            "adopt-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: stageURL)
            if replacingDestination, fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stageURL, to: destinationURL)
            try fileManager.removeItem(at: sourceURL)
        } catch {
            try? fileManager.removeItem(at: stageURL)
        }
    }

    /// The sidecar-declared digest, returned only when the payload bytes
    /// actually hash to it — collision decisions trust bytes, never
    /// declarations.
    private func verifiedPayloadDigest(inPackage packageURL: URL) -> String? {
        guard let sidecar = try? Data(
            contentsOf: packageURL.appendingPathComponent(Self.sidecarFilename)
        ),
            let attachment = try? JSONDecoder().decode(PendingAttachment.self, from: sidecar),
            SpoolPrimitives.isSafeFilename(attachment.filename),
            let payload = try? Data(
                contentsOf: packageURL.appendingPathComponent(attachment.filename)
            ),
            SpoolPrimitives.sha256Hex(payload) == attachment.sha256
        else { return nil }
        return attachment.sha256
    }

    private func collectStagingGarbage(in directory: URL, now: Date) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entryURL in entries {
            guard let modified = try? entryURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                now.timeIntervalSince(modified) > Self.stagingGarbageAge else { continue }
            try? fileManager.removeItem(at: entryURL)
        }
    }

    private func inventory(packages: [URL]) -> PendingAttachmentInventory {
        var attachments: [PendingAttachment] = []
        var recoveryItems: [AttachmentRecoveryItem] = []

        for packageURL in packages {
            let name = packageURL.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard (try? packageURL.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true else { continue }

            let attachment: PendingAttachment
            do {
                let data = try Data(
                    contentsOf: packageURL.appendingPathComponent(Self.sidecarFilename)
                )
                attachment = try JSONDecoder().decode(PendingAttachment.self, from: data)
            } catch {
                recoveryItems.append(AttachmentRecoveryItem(
                    id: "metadata-\(name)",
                    reason: .unreadableMetadata,
                    packageURL: packageURL,
                    detail: error.localizedDescription
                ))
                continue
            }

            guard attachment.id == name else {
                recoveryItems.append(AttachmentRecoveryItem(
                    id: "identity-\(name)",
                    reason: .metadataIdentityMismatch,
                    packageURL: packageURL,
                    detail: "The package name and attachment ID do not match."
                ))
                continue
            }

            guard SpoolPrimitives.isSafeFilename(attachment.filename) else {
                recoveryItems.append(AttachmentRecoveryItem(
                    id: "unsafe-\(name)",
                    reason: .unsafePayloadPath,
                    packageURL: packageURL,
                    detail: "The metadata contains an unsafe payload filename."
                ))
                continue
            }

            guard fileManager.fileExists(
                atPath: packageURL.appendingPathComponent(attachment.filename).path
            ) else {
                recoveryItems.append(AttachmentRecoveryItem(
                    id: "missing-payload-\(name)",
                    reason: .metadataWithoutPayload,
                    packageURL: packageURL,
                    detail: "The attachment metadata exists, but its image file is missing."
                ))
                continue
            }

            if let rawReason = attachment.recoveryReason {
                recoveryItems.append(AttachmentRecoveryItem(
                    id: "quarantined-\(name)",
                    reason: AttachmentRecoveryItem.Reason(rawValue: rawReason)
                        ?? .unreadableMetadata,
                    packageURL: packageURL,
                    detail: attachment.recoveryDetail
                        ?? "The attachment requires manual recovery."
                ))
                continue
            }
            attachments.append(attachment)
        }

        attachments.sort { ($0.enqueuedAtMs, $0.id) < ($1.enqueuedAtMs, $1.id) }
        recoveryItems.sort { $0.id < $1.id }
        return PendingAttachmentInventory(
            attachments: attachments,
            recoveryItems: recoveryItems
        )
    }

    private func directories(in directory: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    /// Captions are fixed at first upload and bounded server-side at 4 KiB;
    /// enforce the same bound at intake on a character boundary.
    static func boundedCaption(_ caption: String?) -> String? {
        guard var trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        while trimmed.utf8.count > maximumCaptionBytes {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
