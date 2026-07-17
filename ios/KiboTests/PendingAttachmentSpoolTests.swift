import XCTest
@testable import Kibo

final class PendingAttachmentSpoolTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        rootURL = nil
        try super.tearDownWithError()
    }

    func testEnqueueCommitsPackageAndRoundTrips() throws {
        let spool = PendingAttachmentSpool(rootURL: rootURL)
        let image = normalizedFixture()

        let attachment = try spool.enqueue(
            image: image,
            serverURL: "https://example.test/",
            projectID: "project", conversationID: "conversation",
            caption: "  a whiteboard  ",
            source: "library"
        )

        let inventory = spool.inventory()
        XCTAssertTrue(inventory.recoveryItems.isEmpty)
        let restored = try XCTUnwrap(inventory.attachments.first)
        XCTAssertEqual(restored.id, attachment.id)
        XCTAssertEqual(restored.destinationKey, "project/conversation")
        XCTAssertEqual(restored.sha256, image.sha256)
        XCTAssertEqual(restored.width, image.width)
        XCTAssertEqual(restored.height, image.height)
        XCTAssertEqual(restored.recordedAt, image.recordedAt)
        XCTAssertEqual(restored.mime, "image/jpeg")
        XCTAssertEqual(restored.caption, "a whiteboard")
        XCTAssertEqual(restored.schemaVersion, PendingAttachment.currentSchemaVersion)
        XCTAssertEqual(
            try Data(contentsOf: spool.payloadURL(for: restored)), image.data
        )
        // Staging left nothing behind: the rename was the commit.
        XCTAssertEqual(try contents(of: rootURL.appendingPathComponent("tmp")), [])
    }

    func testPartiallyStagedPackagesAreInvisibleAtEveryCrashBoundary() throws {
        let spool = PendingAttachmentSpool(rootURL: rootURL)
        let stagingURL = rootURL.appendingPathComponent("tmp", isDirectory: true)

        // Crash boundary 1: stage directory created, nothing written yet.
        let bareStage = stagingURL.appendingPathComponent("stage-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: bareStage, withIntermediateDirectories: true)
        // Crash boundary 2: payload written, sidecar missing.
        let payloadStage = stagingURL.appendingPathComponent("stage-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: payloadStage, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: payloadStage.appendingPathComponent("image-x.jpg"))
        // Crash boundary 3: complete package staged but never renamed.
        let completeStage = stagingURL.appendingPathComponent("stage-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: completeStage, withIntermediateDirectories: true)
        let staged = try spool.enqueue(
            image: normalizedFixture(),
            serverURL: "https://example.test/",
            projectID: "p", conversationID: "c",
            source: "library"
        )
        // Move the committed package back into tmp to simulate the
        // crash-before-rename state without private API access.
        try FileManager.default.removeItem(at: completeStage)
        try FileManager.default.moveItem(
            at: rootURL.appendingPathComponent("pending/\(staged.id)", isDirectory: true),
            to: completeStage
        )

        let inventory = spool.inventory()
        XCTAssertTrue(inventory.attachments.isEmpty)
        XCTAssertTrue(
            inventory.recoveryItems.isEmpty,
            "Un-renamed staging packages must never surface as recovery items"
        )
    }

    func testStagingGarbageCollectionOnlyDeletesPackagesOlderThanADay() throws {
        let spool = PendingAttachmentSpool(rootURL: rootURL)
        let stagingURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        let fresh = stagingURL.appendingPathComponent("stage-fresh")
        let stale = stagingURL.appendingPathComponent("stage-stale")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data([1]).write(to: fresh.appendingPathComponent("image-a.jpg"))
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([2]).write(to: stale.appendingPathComponent("image-b.jpg"))

        // A sweep "now" only 23h after staging must not touch either package —
        // an extension mid-stage can never lose its package to the sweep.
        let stagedAt = Date()
        spool.sweep(now: stagedAt.addingTimeInterval(23 * 60 * 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))

        try FileManager.default.setAttributes(
            [.modificationDate: stagedAt.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        spool.sweep(now: stagedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// Honesty note: these writers are parallel TASKS in one process — the
    /// cross-process claim rests on the rename-commit protocol itself, and the
    /// real share-extension flow is the cross-process exercise.
    func testParallelInProcessWritersNeverExposePartialPackagesToTheScanner() async throws {
        let writerCount = 4
        let perWriter = 5
        let root = rootURL!

        let writers = (0..<writerCount).map { writer in
            Task.detached(priority: .userInitiated) {
                let spool = PendingAttachmentSpool(rootURL: root)
                for index in 0..<perWriter {
                    _ = try spool.enqueue(
                        image: NormalizedImage(
                            data: Data("payload-\(writer)-\(index)".utf8),
                            mime: "image/jpeg", fileExtension: "jpg",
                            width: 4, height: 2,
                            sha256: SpoolPrimitives.sha256Hex(
                                Data("payload-\(writer)-\(index)".utf8)
                            ),
                            recordedAt: 1_000 + index
                        ),
                        serverURL: "https://example.test/",
                        projectID: "p", conversationID: "c",
                        source: "test"
                    )
                }
            }
        }

        let scanner = PendingAttachmentSpool(rootURL: root)
        var scans = 0
        while scans < 200 {
            let inventory = scanner.inventory()
            XCTAssertTrue(
                inventory.recoveryItems.isEmpty,
                "A concurrent scan observed a partial package"
            )
            scans += 1
            if inventory.attachments.count == writerCount * perWriter { break }
            await Task.yield()
        }
        for writer in writers { _ = try await writer.value }
        XCTAssertEqual(scanner.inventory().attachments.count, writerCount * perWriter)
    }

    func testSweepDrainsMigrationRootIdempotently() throws {
        let migrationRoot = rootURL.appendingPathComponent("private-root", isDirectory: true)
        let primaryRoot = rootURL.appendingPathComponent("shared-root", isDirectory: true)
        let writer = PendingAttachmentSpool(rootURL: migrationRoot)
        let first = try writer.enqueue(
            image: normalizedFixture(data: Data("one".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        let second = try writer.enqueue(
            image: normalizedFixture(data: Data("two".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )

        let spool = PendingAttachmentSpool(rootURL: primaryRoot, migrationRootURL: migrationRoot)
        spool.sweep()

        XCTAssertEqual(
            Set(spool.inventory().attachments.map(\.id)), Set([first.id, second.id])
        )
        XCTAssertEqual(
            try contents(of: migrationRoot.appendingPathComponent("pending")), [],
            "The private root drains to empty"
        )

        // Idempotent: a second sweep is a no-op.
        spool.sweep()
        XCTAssertEqual(spool.inventory().attachments.count, 2)
        XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
    }

    /// Simulates the interrupted-migration artifact (complete copy on both
    /// sides) in-process on one volume; collisions are decided on verified
    /// payload bytes, never sidecar declarations alone.
    func testSweepAfterInterruptedMigrationDropsOnlyByteVerifiedDuplicates() throws {
        let migrationRoot = rootURL.appendingPathComponent("private-root", isDirectory: true)
        let primaryRoot = rootURL.appendingPathComponent("shared-root", isDirectory: true)
        let writer = PendingAttachmentSpool(rootURL: migrationRoot)
        let duplicate = try writer.enqueue(
            image: normalizedFixture(data: Data("dup".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        let conflicted = try writer.enqueue(
            image: normalizedFixture(data: Data("theirs".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        let spool = PendingAttachmentSpool(rootURL: primaryRoot, migrationRootURL: migrationRoot)
        _ = spool.inventory() // materialize the primary directory tree
        let migrationPending = migrationRoot.appendingPathComponent("pending", isDirectory: true)
        let primaryPending = primaryRoot.appendingPathComponent("pending", isDirectory: true)
        // Simulated crash mid-move: the duplicate was already copied into the
        // primary root, the source not yet removed.
        try FileManager.default.copyItem(
            at: migrationPending.appendingPathComponent(duplicate.id),
            to: primaryPending.appendingPathComponent(duplicate.id)
        )
        // Same-id collision with DIFFERENT bytes already committed: must never
        // destroy either side.
        let conflictPackage = primaryPending.appendingPathComponent(conflicted.id, isDirectory: true)
        try FileManager.default.createDirectory(at: conflictPackage, withIntermediateDirectories: true)
        let mine = normalizedFixture(data: Data("mine".utf8))
        let mineSidecar = PendingAttachment(
            id: conflicted.id, serverURL: "https://example.test/",
            projectID: "p", conversationID: "c",
            filename: conflicted.filename, mime: "image/jpeg",
            byteCount: mine.data.count, width: mine.width, height: mine.height,
            recordedAt: mine.recordedAt, enqueuedAtMs: 1, sha256: mine.sha256,
            caption: nil, source: "test"
        )
        try JSONEncoder().encode(mineSidecar).write(
            to: conflictPackage.appendingPathComponent(PendingAttachmentSpool.sidecarFilename)
        )
        try mine.data.write(to: conflictPackage.appendingPathComponent(conflicted.filename))

        spool.sweep()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: migrationPending.appendingPathComponent(duplicate.id).path
            ),
            "A sha-verified duplicate source is dropped"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: migrationPending.appendingPathComponent(conflicted.id).path
            ),
            "A sha conflict never deletes the source"
        )
        XCTAssertEqual(
            try Data(contentsOf: conflictPackage.appendingPathComponent(conflicted.filename)),
            mine.data,
            "A sha conflict never overwrites the committed package"
        )

        // Converged: repeated sweeps change nothing further.
        spool.sweep()
        XCTAssertEqual(spool.inventory().attachments.count, 2)
    }

    /// The cross-volume shape a plain `moveItem` migration could have left
    /// behind: destination sidecar intact, payload truncated mid-copy. The
    /// sweep must replace the corrupt committed copy with the verified source
    /// — converging without data loss instead of skipping it forever.
    func testSweepReplacesPartialDestinationCopyWithVerifiedSource() throws {
        let migrationRoot = rootURL.appendingPathComponent("private-root", isDirectory: true)
        let primaryRoot = rootURL.appendingPathComponent("shared-root", isDirectory: true)
        let writer = PendingAttachmentSpool(rootURL: migrationRoot)
        let source = try writer.enqueue(
            image: normalizedFixture(data: Data("complete-payload-bytes".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        let spool = PendingAttachmentSpool(rootURL: primaryRoot, migrationRootURL: migrationRoot)
        _ = spool.inventory() // materialize the primary directory tree
        let migrationPending = migrationRoot.appendingPathComponent("pending", isDirectory: true)
        let primaryPending = primaryRoot.appendingPathComponent("pending", isDirectory: true)
        // Partial destination: full sidecar, truncated payload.
        let partial = primaryPending.appendingPathComponent(source.id, isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: migrationPending
                .appendingPathComponent(source.id, isDirectory: true)
                .appendingPathComponent(PendingAttachmentSpool.sidecarFilename),
            to: partial.appendingPathComponent(PendingAttachmentSpool.sidecarFilename)
        )
        try Data("complete-pa".utf8).write(to: partial.appendingPathComponent(source.filename))

        spool.sweep()

        let inventory = spool.inventory()
        XCTAssertTrue(inventory.recoveryItems.isEmpty, "Convergence, not recovery")
        XCTAssertEqual(inventory.attachments.map(\.id), [source.id])
        XCTAssertEqual(
            try Data(contentsOf: spool.payloadURL(for: inventory.attachments[0])),
            Data("complete-payload-bytes".utf8),
            "The verified source bytes replace the truncated copy"
        )
        XCTAssertEqual(
            try contents(of: migrationPending), [],
            "The source drains once its bytes are committed"
        )

        // Converged: another sweep changes nothing.
        spool.sweep()
        XCTAssertEqual(spool.inventory().attachments.count, 1)
    }

    /// A crash between the staged copy and its rename leaves an `adopt-*`
    /// package in the primary tmp/ and the source untouched. The next sweep
    /// re-adopts from the source; the abandoned stage is invisible to the
    /// scanner and is eventually collected by the ordinary age-based GC.
    func testSweepConvergesWhenCrashLeftAStagedAdoptionCopy() throws {
        let migrationRoot = rootURL.appendingPathComponent("private-root", isDirectory: true)
        let primaryRoot = rootURL.appendingPathComponent("shared-root", isDirectory: true)
        let writer = PendingAttachmentSpool(rootURL: migrationRoot)
        let source = try writer.enqueue(
            image: normalizedFixture(data: Data("staged-once".utf8)),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        let spool = PendingAttachmentSpool(rootURL: primaryRoot, migrationRootURL: migrationRoot)
        _ = spool.inventory()
        // Crash artifact: a complete staged copy that never renamed.
        let stage = primaryRoot.appendingPathComponent("tmp/adopt-deadbeef", isDirectory: true)
        try FileManager.default.copyItem(
            at: migrationRoot.appendingPathComponent("pending/\(source.id)", isDirectory: true),
            to: stage
        )

        spool.sweep()

        let inventory = spool.inventory()
        XCTAssertEqual(inventory.attachments.map(\.id), [source.id])
        XCTAssertTrue(inventory.recoveryItems.isEmpty)
        XCTAssertEqual(
            try contents(of: migrationRoot.appendingPathComponent("pending")), [],
            "The source drains via a fresh staged adoption"
        )
        XCTAssertEqual(
            try Data(contentsOf: spool.payloadURL(for: inventory.attachments[0])),
            Data("staged-once".utf8)
        )
    }

    func testQuarantineSurfacesRecoveryWithoutDeletingPayload() throws {
        let spool = PendingAttachmentSpool(rootURL: rootURL)
        let attachment = try spool.enqueue(
            image: normalizedFixture(),
            serverURL: "https://example.test/", projectID: "p", conversationID: "c",
            source: "library"
        )

        try spool.quarantine(
            attachment,
            reason: .payloadChecksumMismatch,
            detail: "The image changed after it was queued."
        )

        let inventory = spool.inventory()
        XCTAssertTrue(inventory.attachments.isEmpty)
        let recovery = try XCTUnwrap(inventory.recoveryItems.first)
        XCTAssertEqual(recovery.reason, .payloadChecksumMismatch)
        XCTAssertEqual(recovery.detail, "The image changed after it was queued.")
        XCTAssertEqual(inventory.protectedCount(for: "https://other.test/"), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: spool.payloadURL(for: attachment).path)
        )

        try spool.remove(recovery)
        XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: spool.payloadURL(for: attachment).path)
        )
    }

    func testInventoryClassifiesEveryBrokenPackageShape() throws {
        let spool = PendingAttachmentSpool(rootURL: rootURL)
        let pendingURL = rootURL.appendingPathComponent("pending", isDirectory: true)
        _ = spool.inventory()

        func writePackage(_ name: String, sidecar: [String: Any]?, payloadName: String?) throws {
            let packageURL = pendingURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            if let sidecar {
                try JSONSerialization.data(withJSONObject: sidecar).write(
                    to: packageURL.appendingPathComponent(PendingAttachmentSpool.sidecarFilename)
                )
            }
            if let payloadName {
                try Data([9]).write(to: packageURL.appendingPathComponent(payloadName))
            }
        }
        func sidecar(id: String, filename: String, schemaVersion: Int = 1) -> [String: Any] {
            [
                "schemaVersion": schemaVersion, "id": id,
                "serverURL": "https://example.test/",
                "projectID": "p", "conversationID": "c",
                "filename": filename, "mime": "image/jpeg", "byteCount": 1,
                "width": 1, "height": 1, "recordedAt": 1, "enqueuedAtMs": 1,
                "sha256": String(repeating: "a", count: 64), "source": "test",
            ]
        }

        try writePackage("no-sidecar", sidecar: nil, payloadName: "image-x.jpg")
        try writePackage(
            "future-schema",
            sidecar: sidecar(id: "future-schema", filename: "image-y.jpg", schemaVersion: 99),
            payloadName: "image-y.jpg"
        )
        try writePackage(
            "identity-mismatch",
            sidecar: sidecar(id: "some-other-id", filename: "image-z.jpg"),
            payloadName: "image-z.jpg"
        )
        try writePackage(
            "unsafe-filename",
            sidecar: sidecar(id: "unsafe-filename", filename: "../escape.jpg"),
            payloadName: nil
        )
        try writePackage(
            "missing-payload",
            sidecar: sidecar(id: "missing-payload", filename: "image-m.jpg"),
            payloadName: nil
        )

        let inventory = spool.inventory()
        XCTAssertTrue(inventory.attachments.isEmpty)
        XCTAssertEqual(
            Set(inventory.recoveryItems.map(\.reason)),
            Set([
                .unreadableMetadata,
                .metadataIdentityMismatch,
                .unsafePayloadPath,
                .metadataWithoutPayload,
            ])
        )
        XCTAssertEqual(inventory.recoveryItems.count, 5)
    }

    func testCaptionIsTrimmedAndBoundedAtFourKibibytes() {
        XCTAssertNil(PendingAttachmentSpool.boundedCaption(nil))
        XCTAssertNil(PendingAttachmentSpool.boundedCaption("   \n "))
        XCTAssertEqual(PendingAttachmentSpool.boundedCaption(" hi "), "hi")
        let oversize = String(repeating: "é", count: 3_000) // 6000 UTF-8 bytes
        let bounded = PendingAttachmentSpool.boundedCaption(oversize)
        XCTAssertNotNil(bounded)
        XCTAssertLessThanOrEqual(bounded!.utf8.count, PendingAttachmentSpool.maximumCaptionBytes)
    }

    // MARK: - Helpers

    private func normalizedFixture(data: Data = Data([1, 2, 3, 4])) -> NormalizedImage {
        NormalizedImage(
            data: data,
            mime: "image/jpeg",
            fileExtension: "jpg",
            width: 4,
            height: 2,
            sha256: SpoolPrimitives.sha256Hex(data),
            recordedAt: 1_234
        )
    }

    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}
