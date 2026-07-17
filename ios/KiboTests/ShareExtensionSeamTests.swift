import XCTest
@testable import Kibo

/// Phase D seams: app-group root selection, the extension-writer → main-app
/// sweep handoff, the destination cache the extension picks from, and the
/// share-sheet caption policy.
@MainActor
final class ShareExtensionSeamTests: XCTestCase {
    private var session: URLSession!
    private var baseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: baseURL)
        baseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Root selection (one decision, at startup)

    func testRootSelectionPrefersTheAppGroupContainerWithMigrationFromAppSupport() {
        let container = URL(fileURLWithPath: "/groups/kibo", isDirectory: true)
        let appSupport = URL(fileURLWithPath: "/app/support", isDirectory: true)

        let roots = PendingAttachmentSpool.resolvedRoots(
            appGroupContainerURL: container, applicationSupportURL: appSupport
        )

        XCTAssertEqual(roots.rootURL.path, "/groups/kibo/PendingAttachments")
        XCTAssertEqual(
            roots.migrationRootURL?.path, "/app/support/PendingAttachments",
            "The Phase C private root must drain into the shared root"
        )
    }

    func testRootSelectionFallsBackToAppSupportWithoutAnAppGroup() {
        let appSupport = URL(fileURLWithPath: "/app/support", isDirectory: true)

        let roots = PendingAttachmentSpool.resolvedRoots(
            appGroupContainerURL: nil, applicationSupportURL: appSupport
        )

        XCTAssertEqual(
            roots.rootURL.path, "/app/support/PendingAttachments",
            "Free-provisioning contingency: exactly the Phase C root"
        )
        XCTAssertNil(roots.migrationRootURL, "Nothing to migrate from when nothing is shared")
    }

    func testMainAppAndExtensionShareTheRealAppGroupSpoolWhenEntitled() throws {
        // Guarded ONLY for the free-provisioning contingency, where there is
        // no container and therefore no extension to agree with. When the
        // container genuinely resolves, everything below is a hard assertion:
        // app and extension must derive the same root and see the same
        // committed package, or Phase D is nonfunctional.
        guard let container = KiboAppGroup.containerURL() else {
            throw XCTSkip("No App Group container (free provisioning) — covered by resolvedRoots tests")
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let appRoots = PendingAttachmentSpool.resolvedRoots(
            appGroupContainerURL: container, applicationSupportURL: applicationSupport
        )
        XCTAssertEqual(
            appRoots.rootURL.path,
            container.appendingPathComponent(PendingAttachmentSpool.directoryName).path,
            "The main app's spool root must live in the shared container"
        )

        // The extension-side writer resolves against the same container…
        let writer = try XCTUnwrap(
            PendingAttachmentSpool.appGroupWriter(),
            "The extension writer must resolve when the container exists"
        )
        // …and a package it commits is visible to the main app's spool.
        let deposited = try writer.enqueue(
            image: normalizedFixture(data: Data("app-group-seam-proof".utf8)),
            serverURL: "https://appgroup-seam.invalid/",
            projectID: "p", conversationID: "c",
            source: "share"
        )
        defer { PendingAttachmentSpool.mainApp().remove(deposited) }
        let visible = PendingAttachmentSpool.mainApp().all().contains {
            $0.id == deposited.id && $0.sha256 == deposited.sha256
        }
        XCTAssertTrue(
            visible,
            "A package committed through the extension writer must be visible to the main app's spool"
        )
    }

    // MARK: - Extension writer → main-app sweep

    func testExtensionEnqueueIsVisibleToTheMainAppAndLegacyRootDrains() throws {
        let groupRoot = baseURL.appendingPathComponent("group", isDirectory: true)
        let legacyRoot = baseURL.appendingPathComponent("legacy", isDirectory: true)

        // The extension constructs a writer against the shared root and ONLY
        // enqueues — no sweep, no GC.
        let extensionWriter = PendingAttachmentSpool(rootURL: groupRoot)
        let shared = try extensionWriter.enqueue(
            image: normalizedFixture(data: Data("shared-bytes".utf8)),
            serverURL: "https://seam.test/", projectID: "p", conversationID: "c",
            caption: "  from the share sheet  ",
            source: "share"
        )
        // A Phase C era attachment still sitting in the private root.
        let legacyWriter = PendingAttachmentSpool(rootURL: legacyRoot)
        let legacy = try legacyWriter.enqueue(
            image: normalizedFixture(data: Data("legacy-bytes".utf8)),
            serverURL: "https://seam.test/", projectID: "p", conversationID: "c",
            source: "library"
        )

        let appSpool = PendingAttachmentSpool(
            rootURL: groupRoot, migrationRootURL: legacyRoot
        )
        appSpool.sweep()

        let inventory = appSpool.inventory()
        XCTAssertTrue(inventory.recoveryItems.isEmpty)
        XCTAssertEqual(
            Set(inventory.attachments.map(\.id)), Set([shared.id, legacy.id])
        )
        let fromExtension = try XCTUnwrap(
            inventory.attachments.first { $0.id == shared.id }
        )
        XCTAssertEqual(fromExtension.caption, "from the share sheet")
        XCTAssertEqual(fromExtension.source, "share")
        XCTAssertEqual(
            try Data(contentsOf: appSpool.payloadURL(for: fromExtension)),
            Data("shared-bytes".utf8)
        )
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                atPath: legacyRoot.appendingPathComponent("pending").path
            )) ?? [], [],
            "The legacy root drains to empty"
        )
    }

    // MARK: - Destination cache

    func testDestinationCacheRoundTripsThroughTheStore() {
        var cache = DestinationCache(serverURL: "https://cache.test/")
        cache.apply(projects: [(id: "p1", name: "Plants"), (id: "p2", name: "Garage")])
        cache.apply(
            conversations: [(id: "c1", name: "General"), (id: "c2", name: "Seedlings")],
            projectID: "p1"
        )
        cache.select(projectID: "p1", conversationID: "c2")

        let store = DestinationCacheStore(rootURL: baseURL)
        store.save(cache)

        XCTAssertEqual(store.load(), cache)
    }

    func testDestinationCacheMergePreservesConversationsAcrossProjectReloads() {
        var cache = DestinationCache(serverURL: "https://cache.test/")
        cache.apply(projects: [(id: "p1", name: "Plants"), (id: "p2", name: "Garage")])
        cache.apply(conversations: [(id: "c1", name: "General")], projectID: "p1")

        // A later project reload renames p1, drops p2, adds p3 — p1's known
        // conversations survive, p3 starts empty.
        cache.apply(projects: [(id: "p1", name: "House Plants"), (id: "p3", name: "Bikes")])

        XCTAssertEqual(cache.projects.map(\.id), ["p1", "p3"])
        XCTAssertEqual(cache.projects[0].name, "House Plants")
        XCTAssertEqual(cache.projects[0].conversations.map(\.id), ["c1"])
        XCTAssertEqual(cache.projects[1].conversations, [])

        // A fresh conversation load is authoritative (renames + deletions).
        cache.apply(conversations: [(id: "c9", name: "Repotting")], projectID: "p1")
        XCTAssertEqual(cache.projects[0].conversations.map(\.id), ["c9"])
    }

    func testDefaultDestinationPrefersLastSelectedThenFirstThenNil() {
        var cache = DestinationCache(serverURL: "https://cache.test/")
        XCTAssertNil(cache.defaultDestination)

        cache.apply(projects: [(id: "p1", name: "Plants"), (id: "p2", name: "Garage")])
        cache.apply(conversations: [(id: "c1", name: "General")], projectID: "p1")
        cache.apply(conversations: [(id: "c2", name: "Tools")], projectID: "p2")

        // No selection: the first cached destination.
        XCTAssertEqual(cache.defaultDestination?.id, "p1/c1")

        cache.select(projectID: "p2", conversationID: "c2")
        let picked = cache.defaultDestination
        XCTAssertEqual(picked?.id, "p2/c2")
        XCTAssertEqual(picked?.projectName, "Garage")
        XCTAssertEqual(picked?.conversationName, "Tools")
        XCTAssertEqual(picked?.serverURL, "https://cache.test/")

        // A stale selection (conversation deleted) falls back to the first.
        cache.apply(conversations: [], projectID: "p2")
        XCTAssertEqual(cache.defaultDestination?.id, "p1/c1")

        XCTAssertEqual(cache.allDestinations.map(\.id), ["p1/c1"])
    }

    func testDestinationCacheStoreToleratesMissingCorruptAndFutureSchemaFiles() throws {
        let store = DestinationCacheStore(rootURL: baseURL)
        XCTAssertNil(store.load(), "Missing file: the extension says 'open Kibo first'")

        let fileURL = baseURL.appendingPathComponent(DestinationCacheStore.filename)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(store.load(), "Corrupt file reads as absent, never traps")

        try Data(
            #"{"schemaVersion":99,"serverURL":"https://x/","projects":[]}"#.utf8
        ).write(to: fileURL)
        XCTAssertNil(store.load(), "A future schema is not misread")
    }

    func testAppStoreWritesTheDestinationCacheThroughTheSelectionCascade() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        let savedProjectID = UserDefaults.standard.string(forKey: "selectedProjectID")
        let savedConversationID = UserDefaults.standard.string(forKey: "selectedConversationID")
        UserDefaults.standard.set("https://cache-write.test/", forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "selectedProjectID")
        UserDefaults.standard.removeObject(forKey: "selectedConversationID")
        defer {
            restore(savedServerURL, forKey: "serverURL")
            restore(savedProjectID, forKey: "selectedProjectID")
            restore(savedConversationID, forKey: "selectedConversationID")
        }
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            let body: Data
            switch path {
            case "/v1/projects":
                body = #"{"projects":[{"id":"p1","name":"Plants","created_at":1}]}"#
                    .data(using: .utf8)!
            case "/v1/projects/p1/conversations":
                body = #"{"conversations":[{"id":"c1","project_id":"p1","name":"General","name_source":"manual","created_at":1,"last_activity_at":1},{"id":"c2","project_id":"p1","name":"Seedlings","name_source":"manual","created_at":2,"last_activity_at":2}]}"#
                    .data(using: .utf8)!
            default:
                body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        // Pre-seed a cache from ANOTHER server: it must be rebuilt, not
        // merged — cached destinations are meaningless across servers.
        let cacheStore = DestinationCacheStore(rootURL: baseURL)
        var stale = DestinationCache(serverURL: "https://old-server.test/")
        stale.apply(projects: [(id: "ghost", name: "Ghost")])
        cacheStore.save(stale)

        let store = AppStore(
            session: session,
            attachmentSpool: try makeSpool(),
            destinationCacheStore: cacheStore
        )
        await store.reloadProjects()

        let cache = try XCTUnwrap(cacheStore.load())
        XCTAssertEqual(cache.serverURL, "https://cache-write.test/")
        XCTAssertEqual(cache.projects.map(\.id), ["p1"], "The stale server's projects are gone")
        XCTAssertEqual(cache.projects[0].name, "Plants")
        XCTAssertEqual(cache.projects[0].conversations.map(\.name), ["General", "Seedlings"])
        XCTAssertEqual(cache.lastSelectedProjectID, "p1")
        XCTAssertEqual(cache.lastSelectedConversationID, "c1")
        XCTAssertEqual(cache.defaultDestination?.id, "p1/c1")

        // A direct selection change updates the extension's default.
        await store.selectConversation("c2")
        XCTAssertEqual(cacheStore.load()?.lastSelectedConversationID, "c2")
        XCTAssertEqual(cacheStore.load()?.defaultDestination?.id, "p1/c2")
    }

    func testServerSwitchResetsTheDestinationCacheEvenWhenTheNewServerIsUnreachable() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        let savedProjectID = UserDefaults.standard.string(forKey: "selectedProjectID")
        let savedConversationID = UserDefaults.standard.string(forKey: "selectedConversationID")
        UserDefaults.standard.set("https://cache-reset-old.test/", forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "selectedProjectID")
        UserDefaults.standard.removeObject(forKey: "selectedConversationID")
        defer {
            restore(savedServerURL, forKey: "serverURL")
            restore(savedProjectID, forKey: "selectedProjectID")
            restore(savedConversationID, forKey: "selectedConversationID")
        }
        StubURLProtocol.handler = { request in
            guard request.url!.host == "cache-reset-old.test" else {
                // The NEW server is unreachable: every request fails.
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
                    )!,
                    Data(#"{"error":"down"}"#.utf8)
                )
            }
            let body: Data
            switch request.url!.path {
            case "/v1/projects":
                body = #"{"projects":[{"id":"p1","name":"Plants","created_at":1}]}"#
                    .data(using: .utf8)!
            case "/v1/projects/p1/conversations":
                body = #"{"conversations":[{"id":"c1","project_id":"p1","name":"General","name_source":"manual","created_at":1,"last_activity_at":1}]}"#
                    .data(using: .utf8)!
            default:
                body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        let cacheStore = DestinationCacheStore(rootURL: baseURL)
        let store = AppStore(
            session: session,
            attachmentSpool: try makeSpool(),
            destinationCacheStore: cacheStore
        )
        store.discardPendingUploads()
        await store.reloadProjects()
        XCTAssertEqual(
            cacheStore.load()?.defaultDestination?.id, "p1/c1",
            "Precondition: the old server's destinations are cached"
        )

        let changed = await store.updateServerURL("https://cache-reset-new.test/")

        XCTAssertFalse(changed, "The new server is unreachable, so the reload fails")
        XCTAssertEqual(
            store.serverURL, "https://cache-reset-new.test/",
            "The switch itself commits before the reload"
        )
        let cache = try XCTUnwrap(cacheStore.load(), "The cache is rewritten, not left stale")
        XCTAssertEqual(cache.serverURL, "https://cache-reset-new.test/")
        XCTAssertTrue(
            cache.projects.isEmpty,
            "No old-server destination may survive the switch"
        )
        XCTAssertNil(
            cache.defaultDestination,
            "With an empty cache the extension honestly says 'open Kibo first' instead of offering the old server's conversations"
        )
    }

    // MARK: - Share-sheet caption policy

    func testShareTextBecomesTheCaptionOfTheFirstSpooledImageOnly() {
        XCTAssertEqual(
            ShareIntake.caption(forSpooledImageAt: 0, sharedText: "  look at this plant  "),
            "look at this plant"
        )
        XCTAssertNil(
            ShareIntake.caption(forSpooledImageAt: 1, sharedText: "look at this plant"),
            "Caption uniformity: later images must not repeat the shared text"
        )
        XCTAssertNil(ShareIntake.caption(forSpooledImageAt: 0, sharedText: "   \n "))
        XCTAssertNil(ShareIntake.caption(forSpooledImageAt: 0, sharedText: nil))
    }

    // MARK: - Extension phase reducer

    func testInitialPhaseCoversTheThreeUnavailableVariantsInDependencyOrder() {
        XCTAssertEqual(
            ShareIntake.initialPhase(spoolAvailable: false, hasDefaultDestination: true, imageCount: 3),
            .unavailable("Sharing into Kibo is not available on this install.")
        )
        // No spool wins over no destination: without an app group there is
        // nothing the destination could fix.
        XCTAssertEqual(
            ShareIntake.initialPhase(spoolAvailable: false, hasDefaultDestination: false, imageCount: 0),
            .unavailable("Sharing into Kibo is not available on this install.")
        )
        XCTAssertEqual(
            ShareIntake.initialPhase(spoolAvailable: true, hasDefaultDestination: false, imageCount: 3),
            .unavailable("Open Kibo first to connect, then share photos here.")
        )
        XCTAssertEqual(
            ShareIntake.initialPhase(spoolAvailable: true, hasDefaultDestination: true, imageCount: 0),
            .unavailable("Kibo can only save shared images.")
        )
        XCTAssertEqual(
            ShareIntake.initialPhase(spoolAvailable: true, hasDefaultDestination: true, imageCount: 1),
            .ready
        )
    }

    func testCompletionPhaseReportsPartialSavesHonestlyAndZeroAsFailure() {
        XCTAssertEqual(
            ShareIntake.completionPhase(spooled: 0, total: 3),
            .failed("Those images could not be saved. Try sharing them again."),
            "Zero successes is a failure, never an empty 'saved'"
        )
        XCTAssertEqual(
            ShareIntake.completionPhase(spooled: 2, total: 3),
            .saved(count: 2, total: 3),
            "A partial save carries the honest count for the UI to disclose"
        )
        XCTAssertEqual(
            ShareIntake.completionPhase(spooled: 3, total: 3),
            .saved(count: 3, total: 3)
        )
    }

    // MARK: - Helpers

    private func makeSpool() throws -> PendingAttachmentSpool {
        let root = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return PendingAttachmentSpool(rootURL: root)
    }

    private func restore(_ value: String?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
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
}
