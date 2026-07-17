import UIKit
import XCTest
@testable import Kibo

@MainActor
final class ImageSupportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Wire contract

    func testImageUploadUsesServerContractHeadersAndCaptionQuery() async throws {
        let payload = Data("fake-jpeg-bytes".utf8)
        let digest = SpoolPrimitives.sha256Hex(payload)
        let lock = NSLock()
        var observedQuery: String?
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/projects/p/conversations/c/images/img-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-Sha256"), digest)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Recorded-At"), "1234")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Width"), "2048")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Height"), "1365")
            lock.withLock { observedQuery = request.url?.query(percentEncoded: true) }
            let body = #"{"image_id":"img-1","created":true}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        // Captions are fixed at first upload, so any encode/decode asymmetry
        // is PERMANENT corruption. Assert against the RAW percent-encoded
        // query (a URLComponents round-trip would mask the classic bare-"+"
        // bug: the server's form decoding reads "+" as a space) by mimicking
        // the server's decoder: split on "&", "+" → space, percent-decode.
        let hostileCaptions = [
            "C++ notes & 100% done",
            "a caption with spaces & symbols",
            "50%+ faster = better?",
            "caf\u{E9} composed",            // é as one scalar
            "cafe\u{301} decomposed",        // e + combining acute
            "写真のメモ 📷",
        ]
        for caption in hostileCaptions {
            lock.withLock { observedQuery = nil }
            try await api.uploadImage(
                fileURL: url, projectID: "p", conversationID: "c",
                imageID: "img-1", mime: "image/jpeg", width: 2048, height: 1365,
                recordedAt: 1234, caption: caption,
                expectedSHA256: digest
            )
            let raw = try XCTUnwrap(lock.withLock { observedQuery })
            let pair = try XCTUnwrap(
                raw.split(separator: "&").first { $0.hasPrefix("caption=") }
            )
            let encodedValue = String(pair.dropFirst("caption=".count))
            XCTAssertFalse(
                encodedValue.contains("+"),
                "A bare '+' in \(raw) decodes server-side as a space"
            )
            let decoded = encodedValue
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            XCTAssertEqual(
                decoded, caption,
                "Form-decoding must reproduce the caption byte-for-byte"
            )
        }
    }

    func testImageUploadRejectsMismatchedReceipt() async throws {
        let payload = Data("fake-jpeg-bytes".utf8)
        StubURLProtocol.handler = { request in
            let body = #"{"image_id":"some-other-image","created":true}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        do {
            try await api.uploadImage(
                fileURL: url, projectID: "p", conversationID: "c",
                imageID: "img-1", mime: "image/jpeg", width: 1, height: 1,
                recordedAt: 1, expectedSHA256: SpoolPrimitives.sha256Hex(payload)
            )
            XCTFail("A receipt for a different image must not acknowledge this upload")
        } catch APIError.invalidResponse {
            // Expected.
        }
    }

    func testImageUploadRefusesChangedPayloadBeforeNetwork() async throws {
        StubURLProtocol.handler = { request in
            XCTFail("Changed image bytes must not reach the network")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("current-bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        do {
            try await api.uploadImage(
                fileURL: url, projectID: "p", conversationID: "c",
                imageID: "img-1", mime: "image/jpeg", width: 1, height: 1,
                recordedAt: 1, expectedSHA256: String(repeating: "0", count: 64)
            )
            XCTFail("Changed image bytes must be retained for recovery")
        } catch APIError.localAttachmentChanged {
            // Expected.
        }
    }

    func testTurnResponseToleratesAnOldServerWithoutImages() throws {
        let legacy = #"{"turn_id":"t","clips":["c1"],"created":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TurnResponse.self, from: legacy)
        XCTAssertNil(decoded.images)
        XCTAssertEqual(decoded.images ?? [], [])

        let current = #"{"turn_id":"t","clips":[],"images":["img-1"],"created":true}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(TurnResponse.self, from: current).images, ["img-1"]
        )
    }

    // MARK: - Verified cache

    func testImageCacheRejectsShaMismatchedDownloadAndCachesVerifiedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try pngFixture()
        let digest = SpoolPrimitives.sha256Hex(good)

        let cache = ConversationImageCache(directoryURL: directory)
        do {
            _ = try await cache.image(sha256: digest) { Data("corrupted-download".utf8) }
            XCTFail("Mismatched bytes must be rejected")
        } catch ConversationImageCache.CacheError.checksumMismatch {
            // Expected.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(digest).path),
            "Rejected bytes must never reach the cache"
        )

        _ = try await cache.image(sha256: digest) { good }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(digest).path)
        )

        // A fresh instance (cold memory) serves the verified disk copy without
        // refetching.
        let reopened = ConversationImageCache(directoryURL: directory)
        _ = try await reopened.image(sha256: digest) {
            XCTFail("A cached image must not be fetched again")
            return Data()
        }
    }

    // MARK: - Timeline projection

    func testTimelineMergesClaimedImagesAndClipsByRecordedAtThenSeq() throws {
        let sha = String(repeating: "a", count: 64)
        let data = #"[{"seq":1,"kind":"clip","id":"c1","recorded_at":200},{"seq":2,"kind":"image","id":"img1","file":"images/img1.jpg","mime":"image/jpeg","sha256":"\#(sha)","recorded_at":100,"width":1024,"height":512,"caption":"whiteboard"},{"seq":3,"kind":"transcript","clip":"c1","text":"Hello"},{"seq":4,"kind":"turn","id":"t1","clips":["c1"],"images":["img1"]},{"seq":5,"kind":"reply","turn":"t1","text":"Hi"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        let cards = events.timeline()
        XCTAssertEqual(cards.map(\.id), ["image-img1", "clip-c1", "kibo-t1"])
        let imageCard = cards[0]
        XCTAssertEqual(imageCard.role, .person)
        XCTAssertEqual(imageCard.title, "You")
        XCTAssertEqual(imageCard.body, "whiteboard")
        XCTAssertEqual(imageCard.imageID, "img1")
        XCTAssertEqual(imageCard.imageSHA256, sha)
        XCTAssertEqual(imageCard.imageAspectRatio, 2.0)
        XCTAssertFalse(imageCard.canPlay)
        XCTAssertTrue(events.unclaimedImageIDs.isEmpty)
    }

    func testUnclaimedImageRendersNotAskedYetCard() throws {
        let sha = String(repeating: "b", count: 64)
        let data = #"[{"seq":1,"kind":"image","id":"img1","file":"images/img1.jpg","mime":"image/png","sha256":"\#(sha)","recorded_at":10}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        let cards = events.timeline()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].title, "You · not asked yet")
        XCTAssertEqual(cards[0].imageID, "img1")
        XCTAssertEqual(cards[0].body, "")
        XCTAssertNil(cards[0].imageAspectRatio)
        XCTAssertEqual(events.unclaimedImageIDs, ["img1"])
        XCTAssertEqual(events.unclaimedMediaCount, 1)
    }

    func testUnclaimedMediaCountCombinesClipsAndImages() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"image","id":"img1","sha256":"x"},{"seq":3,"kind":"image","id":"img2","sha256":"y"},{"seq":4,"kind":"turn","id":"t1","clips":[],"images":["img2"]}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.unclaimedClipCount, 1)
        XCTAssertEqual(events.unclaimedImageIDs, ["img1"])
        XCTAssertEqual(events.unclaimedMediaCount, 2)
    }

    // MARK: - Store gating

    func testAskableItemCountCountsUnclaimedImagesAndLocalAttachmentsForDestination() throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://askable.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        let spool = try makeSpool()

        let store = AppStore(session: session, attachmentSpool: spool)
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"
        let data = #"[{"seq":1,"kind":"image","id":"img1","sha256":"x"}]"#.data(using: .utf8)!
        store.events = try JSONDecoder().decode([KiboEvent].self, from: data)

        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("mine".utf8)),
            serverURL: "https://askable.test/", projectID: "p", conversationID: "c",
            source: "test"
        )
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("elsewhere".utf8)),
            serverURL: "https://askable.test/", projectID: "p", conversationID: "other",
            source: "test"
        )
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("other-server".utf8)),
            serverURL: "https://unrelated.test/", projectID: "p", conversationID: "c",
            source: "test"
        )
        store.refreshRecordingInventory()

        XCTAssertEqual(store.localAskableAttachmentCount, 1)
        XCTAssertEqual(
            store.askableItemCount, 2,
            "One unclaimed server image plus one local attachment for the selected destination"
        )
    }

    func testSubmitTurnDrainsPendingImageUploadsBeforePosting() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://image-drain.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let lock = NSLock()
        var operations: [String] = []
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "PUT", path.contains("/images/") {
                lock.withLock { operations.append("put-image") }
                let imageID = request.url!.lastPathComponent
                let body = #"{"image_id":"\#(imageID)","created":true}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            if request.httpMethod == "POST", path.hasSuffix("/turns") {
                lock.withLock { operations.append("post-turn") }
                let body = #"{"turn_id":"accepted","clips":[],"created":true}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool)
        store.discardPendingUploads()
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("payload".utf8)),
            serverURL: "https://image-drain.test/",
            projectID: "project", conversationID: "conversation",
            source: "test"
        )
        store.refreshRecordingInventory()

        let turnID = await store.submitTurn()

        XCTAssertNotNil(turnID)
        XCTAssertEqual(
            lock.withLock { operations }, ["put-image", "post-turn"],
            "An ask must drain its own pending image before the turn posts"
        )
        XCTAssertTrue(spool.all().isEmpty)
    }

    func testSubmitTurnRefusesWhileAttachmentRecoveryExists() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://image-recovery.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTFail("No turn may post while attachment recovery items exist")
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool)
        store.discardPendingUploads()
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        let attachment = try spool.enqueue(
            image: normalizedFixture(data: Data("payload".utf8)),
            serverURL: "https://image-recovery.test/",
            projectID: "project", conversationID: "conversation",
            source: "test"
        )
        try spool.quarantine(
            attachment, reason: .payloadChecksumMismatch, detail: "changed"
        )

        let turnID = await store.submitTurn()

        XCTAssertNil(turnID)
        XCTAssertEqual(store.recoveryItemCount, 1)
    }

    func testServerChangeIsBlockedByPendingAttachments() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://attachment-pin.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        StubURLProtocol.handler = { request in
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool)
        store.discardPendingUploads()
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("pinned".utf8)),
            serverURL: "https://attachment-pin.test/",
            projectID: "p", conversationID: "c",
            source: "test"
        )

        let changed = await store.updateServerURL("https://other-server.test/")

        XCTAssertFalse(changed)
        XCTAssertEqual(store.serverURL, "https://attachment-pin.test/")
        XCTAssertNotNil(store.errorMessage)
    }

    func testResumePendingWorkDrainsMigrationRootAndUploads() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://sweep-upload.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let lock = NSLock()
        var uploadedIDs: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT", request.url!.path.contains("/images/") {
                let imageID = request.url!.lastPathComponent
                lock.withLock { uploadedIDs.append(imageID) }
                let body = #"{"image_id":"\#(imageID)","created":true}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let primaryRoot = base.appendingPathComponent("shared", isDirectory: true)
        let migrationRoot = base.appendingPathComponent("private", isDirectory: true)
        let extensionWriter = PendingAttachmentSpool(rootURL: migrationRoot)
        let deposited = try extensionWriter.enqueue(
            image: normalizedFixture(data: Data("shared-image".utf8)),
            serverURL: "https://sweep-upload.test/",
            projectID: "p", conversationID: "c",
            source: "share"
        )

        let spool = PendingAttachmentSpool(rootURL: primaryRoot, migrationRootURL: migrationRoot)
        let store = AppStore(session: session, attachmentSpool: spool)
        store.discardPendingUploads()
        store.resumePendingWork()

        await eventually {
            lock.withLock { uploadedIDs } == [deposited.id] && spool.all().isEmpty
        }
        XCTAssertTrue(
            PendingAttachmentSpool(rootURL: migrationRoot).all().isEmpty,
            "The migration root drains to empty"
        )
    }

    func testQueueImageNormalizesSpoolsAndUploadsThroughTheTrackedTask() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://queue-image.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let lock = NSLock()
        var uploadedDigests: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT", request.url!.path.contains("/images/") {
                if let digest = request.value(forHTTPHeaderField: "X-Content-Sha256") {
                    lock.withLock { uploadedDigests.append(digest) }
                }
                let imageID = request.url!.lastPathComponent
                let body = #"{"image_id":"\#(imageID)","created":true}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool)
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"

        store.queueImage(data: try pngFixture(), source: "test")
        await store.waitForRecordingTasks()

        let digests = lock.withLock { uploadedDigests }
        XCTAssertEqual(digests.count, 1)
        XCTAssertEqual(digests.first?.count, 64)
        XCTAssertTrue(spool.all().isEmpty, "An acknowledged upload leaves the spool")
        XCTAssertEqual(store.localAskableAttachmentCount, 0)
    }

    func testPermanentServerRejectionQuarantinesAttachmentInsteadOfRetryingForever() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://reject.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let lock = NSLock()
        var putCount = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT", request.url!.path.contains("/images/") {
                lock.withLock { putCount += 1 }
                let body = Data(#"{"error":"image too large"}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool, destinationCacheStore: nil)
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("huge".utf8)),
            serverURL: "https://reject.test/", projectID: "p", conversationID: "c",
            source: "test"
        )
        store.refreshRecordingInventory()

        _ = await store.retryPendingUploads()

        XCTAssertTrue(spool.all().isEmpty, "A rejected attachment must leave the retry ladder")
        let recovery = try XCTUnwrap(spool.inventory().recoveryItems.first)
        XCTAssertEqual(recovery.reason, .serverRejected)
        XCTAssertEqual(store.status, "Photo recovery needed")
        XCTAssertEqual(lock.withLock { putCount }, 1)

        // The quarantined item never re-enters the ladder.
        _ = await store.retryPendingUploads()
        XCTAssertEqual(lock.withLock { putCount }, 1, "Permanent rejections must not retry")
    }

    func testServerChangeAwaitsInFlightImageIntakeInsteadOfStrandingIt() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://intake-race.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                // Upload fails, so the freshly spooled attachment stays
                // pending and must pin the server.
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let slowResult = normalizedFixture(data: Data("slow-normalize".utf8))
        let store = AppStore(
            session: session,
            attachmentSpool: spool,
            destinationCacheStore: nil,
            normalizeImage: { _, _ in
                // Deliberately slow: the switch must wait for this intake.
                Thread.sleep(forTimeInterval: 0.3)
                return slowResult
            }
        )
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"

        store.queueImage(data: Data("raw".utf8), source: "test")
        let changed = await store.updateServerURL("https://elsewhere.test/")

        XCTAssertFalse(
            changed,
            "A server switch must not race an in-flight intake: the attachment would be stranded"
        )
        XCTAssertEqual(store.serverURL, "https://intake-race.test/")
        XCTAssertEqual(spool.all().map(\.serverURL), ["https://intake-race.test/"])
        store.discardPendingUploads()
    }

    func testHungIntakeBoundsTheServerSwitchWaitAndRefusesTheLateSpool() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://hung-intake.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        StubURLProtocol.handler = { request in
            let body: Data = request.url!.path == "/v1/projects"
                ? #"{"projects":[]}"#.data(using: .utf8)!
                : #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { release.signal() }
        let stalled = normalizedFixture(data: Data("stalled".utf8))
        let store = AppStore(
            session: session,
            attachmentSpool: spool,
            destinationCacheStore: nil,
            normalizeImage: { _, _ in
                // A decoder hang: never returns until the test releases it.
                release.wait()
                return stalled
            }
        )
        store.intakeDrainTimeout = .milliseconds(150)
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"
        store.queueImage(data: Data("raw".utf8), source: "test")

        let changed = await store.updateServerURL("https://elsewhere.test/")

        XCTAssertTrue(
            changed,
            "The switch must proceed once the bounded intake wait expires — a hung decoder cannot wedge Settings forever"
        )
        XCTAssertEqual(store.serverURL, "https://elsewhere.test/")

        // The stalled decode finishing AFTER the switch must be refused at
        // enqueue: its generation is stale.
        release.signal()
        let drained = await store.waitForRecordingTasks(upTo: .seconds(5))
        XCTAssertTrue(drained, "The released intake task must finish")
        XCTAssertTrue(
            spool.all().isEmpty,
            "A stale-generation intake must never spool — it would be stranded on the abandoned server"
        )
    }

    func testPickedBatchHoldsOneGateAndSpoolsToTheCapturedDestinationWithOneTimestamp() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://batch-intake.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                // Uploads fail so the spooled batch stays inspectable.
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(
            session: session,
            attachmentSpool: spool,
            destinationCacheStore: nil,
            normalizeImage: { data, intakeDate in
                NormalizedImage(
                    data: data, mime: "image/jpeg", fileExtension: "jpg",
                    width: 4, height: 2,
                    sha256: SpoolPrimitives.sha256Hex(data),
                    recordedAt: Int(intakeDate.timeIntervalSince1970)
                )
            }
        )
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "c"

        let batch = try XCTUnwrap(store.beginImageIntake(source: "library"))

        // The gate is registered from before the picker dismisses: an Ask's
        // bounded intake wait cannot slip between images of one selection.
        let drainedEarly = await store.waitForRecordingTasks(upTo: .milliseconds(100))
        XCTAssertFalse(drainedEarly, "The batch gate must hold while the selection is still loading")

        await batch.add(Data("first".utf8))
        // Mid-batch navigation must not redirect the rest of the selection.
        store.selectedProjectID = "px"
        store.selectedConversationID = "cx"
        await batch.add(Data("second".utf8))
        batch.finish()

        let drained = await store.waitForRecordingTasks(upTo: .seconds(10))
        XCTAssertTrue(drained, "finish() releases the gate")

        let spooled = spool.all()
        XCTAssertEqual(spooled.count, 2)
        XCTAssertEqual(
            spooled.map(\.destinationKey), ["p/c", "p/c"],
            "Every image in the batch lands in the destination captured at begin"
        )
        XCTAssertEqual(
            Set(spooled.map(\.recordedAt)), [Int(batch.intakeDate.timeIntervalSince1970)],
            "All images in one batch share the single captured intake timestamp"
        )
        store.discardPendingUploads()
    }

    func testDiscardPendingUploadsRemovesForeignServerAttachmentPackages() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://current-server.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool, destinationCacheStore: nil)
        // A package the share extension deposited against a server the app
        // has since left: invisible to every counter and retry pass, so
        // discard is its only exit.
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("foreign".utf8)),
            serverURL: "https://old-server.test/", projectID: "p", conversationID: "c",
            source: "share"
        )
        store.refreshRecordingInventory()
        XCTAssertEqual(
            store.pendingUploadCount, 0,
            "Precondition: the foreign package is invisible to the pending count"
        )

        store.discardPendingUploads()

        XCTAssertTrue(
            spool.all().isEmpty,
            "Discard must remove foreign-server packages — nothing else ever touches them"
        )
    }

    func testUnknownConversation404QuarantinesAttachmentInsteadOfRetryingForever() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://gone.test/", forKey: "serverURL")
        defer { restoreServerURL(savedServerURL) }

        let lock = NSLock()
        var putCount = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT", request.url!.path.contains("/images/") {
                lock.withLock { putCount += 1 }
                let body = Data(#"{"error":"unknown conversation"}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let spool = try makeSpool()
        let store = AppStore(session: session, attachmentSpool: spool, destinationCacheStore: nil)
        store.discardPendingUploads()
        store.selectedProjectID = "p"
        store.selectedConversationID = "deleted"
        _ = try spool.enqueue(
            image: normalizedFixture(data: Data("orphan".utf8)),
            serverURL: "https://gone.test/", projectID: "p", conversationID: "deleted",
            source: "test"
        )
        store.refreshRecordingInventory()

        _ = await store.retryPendingUploads()

        XCTAssertTrue(spool.all().isEmpty, "A 404'd attachment must leave the retry ladder")
        let recovery = try XCTUnwrap(spool.inventory().recoveryItems.first)
        XCTAssertEqual(recovery.reason, .serverRejected)
        XCTAssertEqual(lock.withLock { putCount }, 1)

        _ = await store.retryPendingUploads()
        XCTAssertEqual(
            lock.withLock { putCount }, 1,
            "kibod 404s unknown conversations permanently — retrying can never succeed"
        )
    }

    func testPendingTailInterleavesUnclaimedClipsAndImagesByRecordedAt() throws {
        // Upload latency must not reorder the conversation: seqs here arrive
        // clip-first, but recorded_at says image, clip, image.
        let sha = String(repeating: "c", count: 64)
        let data = #"[{"seq":1,"kind":"clip","id":"c1","recorded_at":200},{"seq":2,"kind":"image","id":"early","file":"images/early.jpg","mime":"image/jpeg","sha256":"\#(sha)","recorded_at":100},{"seq":3,"kind":"image","id":"late","file":"images/late.jpg","mime":"image/jpeg","sha256":"\#(sha)","recorded_at":300}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        XCTAssertEqual(
            events.timeline().map(\.id),
            ["image-early", "clip-c1", "image-late"],
            "The pending tail merges by (recorded_at, seq), same as claimed media"
        )
    }

    func testTimelineKeepsClaimOrderForMediaWithoutCommitmentEvents() throws {
        // Malformed journals (turn claims media whose events never arrived)
        // all merge with the same (0, 0) key — the claim array's own order is
        // the server order and must survive, not a lexical ID sort.
        let data = #"[{"seq":1,"kind":"turn","id":"t1","clips":["c2","c1"],"images":["img9"]}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        XCTAssertEqual(
            events.timeline().map(\.id),
            ["clip-c2", "clip-c1", "image-img9", "status-t1"]
        )
    }

    // MARK: - Helpers

    private func makeSpool() throws -> PendingAttachmentSpool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return PendingAttachmentSpool(rootURL: root)
    }

    private func restoreServerURL(_ saved: String?) {
        if let saved { UserDefaults.standard.set(saved, forKey: "serverURL") }
        else { UserDefaults.standard.removeObject(forKey: "serverURL") }
    }

    private func normalizedFixture(data: Data) -> NormalizedImage {
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

    private func pngFixture() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}
