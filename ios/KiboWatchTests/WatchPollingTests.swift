import XCTest
@testable import Kibo_Watch

/// Phase 0 polling hygiene: delta-cursor event fetches, adaptive cadence,
/// and scene gating (Tier 2 plan §3 Phase 0).
@MainActor
final class WatchPollingTests: XCTestCase {
    private static let defaultsKeys = [
        "watchServerURL", "watchSelectedProjectID", "watchSelectedConversationID",
    ]

    private var session: URLSession!
    private var savedDefaults: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollingStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        for key in Self.defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.string(forKey: key)
        }
        UserDefaults.standard.set("https://polling.test/", forKey: "watchServerURL")
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        PollingStubURLProtocol.handler = nil
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testRefreshEventsFetchesDeltasAndAppends() async {
        let lock = NSLock()
        var afterValues: [String?] = []
        PollingStubURLProtocol.handler = { request in
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after" }?.value
            let requestNumber = lock.withLock {
                afterValues.append(after)
                return afterValues.count
            }
            let body = requestNumber == 1
                ? #"{"events":[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi"}],"latest_seq":2}"#
                : #"{"events":[{"seq":3,"kind":"clip","id":"c9","ms":1000}],"latest_seq":3}"#
            return (Self.ok(request), body.data(using: .utf8)!)
        }

        let store = WatchStore(session: session)
        store.selectedProjectID = "p1"
        store.selectedConversationID = "c1"

        let firstAccepted = await store.refreshEvents()
        XCTAssertTrue(firstAccepted)
        XCTAssertEqual(store.events.map(\.seq), [1, 2])
        XCTAssertEqual(store.eventsCursor, 2)
        XCTAssertEqual(store.eventRevision, 1)

        let secondAccepted = await store.refreshEvents()
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(lock.withLock { afterValues }, ["0", "2"])
        XCTAssertEqual(store.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(store.eventsCursor, 3)
        XCTAssertEqual(store.eventRevision, 2)
    }

    func testSelectionChangeResetsCursorAndEventLog() async {
        let lock = NSLock()
        var afterValues: [String?] = []
        PollingStubURLProtocol.handler = { request in
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after" }?.value
            lock.withLock { afterValues.append(after) }
            let body = request.url!.path.contains("/conversations/c1/")
                ? #"{"events":[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi"}],"latest_seq":2}"#
                : #"{"events":[{"seq":9,"kind":"turn","id":"t9","clips":[]}],"latest_seq":9}"#
            return (Self.ok(request), body.data(using: .utf8)!)
        }

        let store = WatchStore(session: session)
        store.selectedProjectID = "p1"
        store.selectedConversationID = "c1"
        let accepted = await store.refreshEvents()
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.eventsCursor, 2)

        await store.selectConversation("c2")

        // The switch must refetch from zero into an emptied log — [9], not
        // [1, 2, 9].
        XCTAssertEqual(lock.withLock { afterValues }, ["0", "0"])
        XCTAssertEqual(store.events.map(\.seq), [9])
        XCTAssertEqual(store.eventsCursor, 9)

        await store.selectProject(nil)
        XCTAssertEqual(store.events, [])
        XCTAssertEqual(store.eventsCursor, 0)
    }

    func testNeedsFastPollingTruthTable() throws {
        func events(_ json: String) throws -> [KiboEvent] {
            try JSONDecoder().decode([KiboEvent].self, from: json.data(using: .utf8)!)
        }
        let turn = #"{"seq":1,"kind":"turn","id":"t1","clips":[]}"#
        let audioReply = #"{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"}"#

        // No conversation activity.
        XCTAssertFalse(try events("[]").needsFastPolling)
        // Reply pending.
        XCTAssertTrue(try events("[\(turn)]").needsFastPolling)
        // Reply retry scheduled is still pending.
        XCTAssertTrue(try events(
            "[\(turn),\(#"{"seq":2,"kind":"reply_retry_scheduled","turn":"t1"}"#)]"
        ).needsFastPolling)
        // Terminal reply failure is settled.
        XCTAssertFalse(try events(
            "[\(turn),\(#"{"seq":2,"kind":"reply_error","turn":"t1","terminal":true,"error":"boom"}"#)]"
        ).needsFastPolling)
        // Reply ready with audio: speech is still owed.
        XCTAssertTrue(try events("[\(turn),\(audioReply)]").needsFastPolling)
        // Speech streaming.
        XCTAssertTrue(try events(
            "[\(turn),\(audioReply),\(#"{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}"#)]"
        ).needsFastPolling)
        // Speech done.
        XCTAssertFalse(try events(
            "[\(turn),\(audioReply),\(#"{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}"#),\(#"{"seq":4,"kind":"speech_ready","turn":"t1","attempt":1}"#)]"
        ).needsFastPolling)
        // Speech terminally failed is settled.
        XCTAssertFalse(try events(
            "[\(turn),\(audioReply),\(#"{"seq":3,"kind":"tts_error","turn":"t1","terminal":true,"error":"boom"}"#)]"
        ).needsFastPolling)
        // Text-only reply owes no speech.
        XCTAssertFalse(try events(
            "[\(turn),\(#"{"seq":2,"kind":"reply","turn":"t1","text":"Hi"}"#)]"
        ).needsFastPolling)
        // Unclaimed clip transcription is not wrist-visible work.
        XCTAssertFalse(try events(
            #"[{"seq":1,"kind":"clip","id":"c1","ms":1000}]"#
        ).needsFastPolling)
    }

    func testPollIntervalCadenceTruthTable() throws {
        let store = WatchStore(session: session)
        let t0 = ContinuousClock.now

        // No projects yet: load() retries at the idle cadence.
        XCTAssertEqual(store.nextPollInterval(now: t0), WatchStore.idlePollInterval)

        store.projects = [KiboProject(id: "p1", name: "One", created_at: 0)]
        XCTAssertEqual(store.nextPollInterval(now: t0), WatchStore.idlePollInterval)

        // Submitting turns on the fast cadence.
        store.isSubmitting = true
        XCTAssertEqual(store.nextPollInterval(now: t0), WatchStore.fastPollInterval)
        XCTAssertEqual(
            store.nextPollInterval(now: t0.advanced(by: .seconds(119))),
            WatchStore.fastPollInterval
        )
        // An unresolved fast window degrades to idle.
        XCTAssertEqual(
            store.nextPollInterval(now: t0.advanced(by: .seconds(121))),
            WatchStore.idlePollInterval
        )

        // Resolution resets the window…
        store.isSubmitting = false
        XCTAssertEqual(
            store.nextPollInterval(now: t0.advanced(by: .seconds(122))),
            WatchStore.idlePollInterval
        )

        // …so newly pending work gets a fresh fast window, and pending
        // events drive the cadence just like isSubmitting.
        store.events = try JSONDecoder().decode(
            [KiboEvent].self,
            from: #"[{"seq":1,"kind":"turn","id":"t1","clips":[]}]"#.data(using: .utf8)!
        )
        XCTAssertEqual(
            store.nextPollInterval(now: t0.advanced(by: .seconds(123))),
            WatchStore.fastPollInterval
        )
        XCTAssertEqual(
            store.nextPollInterval(now: t0.advanced(by: .seconds(244))),
            WatchStore.idlePollInterval
        )
    }

    func testSceneGatingStopsAndRestartsThePollLoop() async {
        PollingStubURLProtocol.handler = { request in
            let body = request.url!.path.hasSuffix("/projects")
                ? #"{"projects":[]}"#
                : #"{"events":[],"latest_seq":0}"#
            return (Self.ok(request), body.data(using: .utf8)!)
        }

        let store = WatchStore(session: session)
        XCTAssertFalse(store.isPolling)

        await store.start()
        XCTAssertTrue(store.isPolling)

        store.setSceneActive(false)
        XCTAssertFalse(store.isPolling)

        store.setSceneActive(true)
        XCTAssertTrue(store.isPolling)

        store.setSceneActive(false)
        XCTAssertFalse(store.isPolling)
    }

    func testStartWhileSceneInactiveDefersPollingUntilActivation() async {
        PollingStubURLProtocol.handler = { request in
            let body = request.url!.path.hasSuffix("/projects")
                ? #"{"projects":[]}"#
                : #"{"events":[],"latest_seq":0}"#
            return (Self.ok(request), body.data(using: .utf8)!)
        }

        let store = WatchStore(session: session)
        store.setSceneActive(false)
        await store.start()
        XCTAssertFalse(store.isPolling)

        store.setSceneActive(true)
        XCTAssertTrue(store.isPolling)
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!
    }
}

private final class PollingStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
