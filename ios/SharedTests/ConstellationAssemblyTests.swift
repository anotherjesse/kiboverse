import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// The shared dedupe + order policy every store's constellation projection
/// routes through: server markers first, then local markers in the order
/// given, skipping IDs the server already owns — with typed local kinds so a
/// quarantined photo renders as a failed diamond, never a voice star.
final class ConstellationAssemblyTests: XCTestCase {
    private var nextSeq: UInt64 = 0

    override func setUp() {
        super.setUp()
        nextSeq = 0
    }

    private func event(_ fields: [String: Any]) -> KiboEvent {
        var fields = fields
        if fields["seq"] == nil {
            nextSeq += 1
            fields["seq"] = nextSeq
        }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(KiboEvent.self, from: data)
    }

    /// A transcribed clip: server-side it lands as an `.unseen` voice marker.
    private func clip(_ id: String, transcribed: Bool = true) -> [KiboEvent] {
        var events = [event(["kind": "clip", "id": id, "ms": 900, "recorded_at": nextSeq + 1])]
        if transcribed {
            events.append(event(["kind": "transcript", "clip": id, "text": "thought \(id)"]))
        }
        return events
    }

    /// A local marker whose id matches a server marker must not duplicate it,
    /// and the server entry — with its real lifecycle phase — wins.
    func testSpoolIdentityHandoffKeepsServerPhase() {
        let events = clip("c1") // server-side transcribed clip → .unseen
        let markers = ConstellationAssembly.markers(
            events: events,
            local: [LocalMarker(id: "c1", kind: .voice, phase: .working)]
        )
        XCTAssertEqual(markers.map(\.id), ["c1"])
        XCTAssertEqual(markers.first?.phase, .unseen)
    }

    /// A recovery marker's "recovery-" prefix keeps it distinct from the raw
    /// server clip id for the same recording, so both render.
    func testRecoveryPrefixDoesNotCollideWithServerMarker() {
        let events = clip("c1")
        let markers = ConstellationAssembly.markers(
            events: events,
            local: [LocalMarker(id: "recovery-c1", kind: .voice, phase: .failed)]
        )
        XCTAssertEqual(markers.map(\.id), ["c1", "recovery-c1"])
    }

    /// A quarantined image renders as a failed image diamond, never a voice
    /// star — the whole reason LocalMarker carries a typed kind.
    func testImageRecoveryRendersAsFailedDiamond() {
        let markers = ConstellationAssembly.markers(
            events: [],
            local: [LocalMarker(id: "recovery-img1", kind: .image, phase: .failed)]
        )
        XCTAssertEqual(markers.map(\.id), ["recovery-img1"])
        XCTAssertEqual(markers.first?.kind, .image)
        XCTAssertEqual(markers.first?.phase, .failed)
    }

    /// No id ever appears twice, even when several locals collide with server
    /// markers: the server always wins the slot.
    func testServerWinsAndNeverDuplicates() {
        var events: [KiboEvent] = []
        events += clip("c1")
        events += clip("c2")
        let markers = ConstellationAssembly.markers(
            events: events,
            local: [
                LocalMarker(id: "c1", kind: .voice, phase: .working),
                LocalMarker(id: "c2", kind: .voice, phase: .working),
            ]
        )
        XCTAssertEqual(markers.map(\.id), ["c1", "c2"])
        XCTAssertEqual(Set(markers.map(\.id)).count, markers.count)
        XCTAssertEqual(markers.map(\.phase), [.unseen, .unseen])
    }

    /// Server markers keep their walk order and lead; non-colliding locals
    /// follow in exactly the input order.
    func testOrderIsServerThenLocalsInInputOrder() {
        var events: [KiboEvent] = []
        events += clip("c1")
        events += clip("c2")
        let markers = ConstellationAssembly.markers(
            events: events,
            local: [
                LocalMarker(id: "spool1", kind: .voice, phase: .working),
                LocalMarker(id: "spool2", kind: .voice, phase: .working),
                LocalMarker(id: "recovery-x", kind: .voice, phase: .failed),
            ]
        )
        XCTAssertEqual(markers.map(\.id), ["c1", "c2", "spool1", "spool2", "recovery-x"])
    }
}

/// The two tiny destination-selection helpers extracted from the four
/// byte-identical copies across AppStore/WatchStore.
final class DestinationSelectionTests: XCTestCase {
    // MARK: - KiboDestination nil-propagating init

    func testDestinationBuildsWhenBothPresent() {
        // Optional-typed inputs force overload resolution to the failable
        // init (the shape `requestDestination` calls), not the memberwise one.
        let projectID: String? = "p1"
        let conversationID: String? = "c1"
        let destination = KiboDestination(
            serverURL: "https://kibo.example", projectID: projectID, conversationID: conversationID
        )
        XCTAssertNotNil(destination)
        XCTAssertEqual(destination?.serverURL, "https://kibo.example")
        XCTAssertEqual(destination?.projectID, "p1")
        XCTAssertEqual(destination?.conversationID, "c1")
    }

    func testDestinationNilWhenProjectMissing() {
        XCTAssertNil(KiboDestination(
            serverURL: "https://kibo.example", projectID: nil, conversationID: "c1"
        ))
    }

    func testDestinationNilWhenConversationMissing() {
        XCTAssertNil(KiboDestination(
            serverURL: "https://kibo.example", projectID: "p1", conversationID: nil
        ))
    }

    func testDestinationNilWhenBothMissing() {
        XCTAssertNil(KiboDestination(
            serverURL: "https://kibo.example", projectID: nil, conversationID: nil
        ))
    }

    // MARK: - PendingClip.matching(serverURL:destinationKey:)

    private func makeClip(_ id: String, serverURL: String, projectID: String, conversationID: String) -> PendingClip {
        PendingClip(
            id: id,
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID,
            wavFilename: "\(id).wav",
            durationMs: 1000,
            peakPct: 50,
            recordedAt: 0,
            enqueuedAtMs: 0,
            sha256: nil
        )
    }

    func testMatchingReturnsOnlyServerAndDestinationSubsetInOrder() {
        let serverA = "https://a.example"
        let serverB = "https://b.example"
        let clips = [
            makeClip("c1", serverURL: serverA, projectID: "p1", conversationID: "conv1"),
            makeClip("c2", serverURL: serverB, projectID: "p1", conversationID: "conv1"),
            makeClip("c3", serverURL: serverA, projectID: "p1", conversationID: "conv2"),
            makeClip("c4", serverURL: serverA, projectID: "p1", conversationID: "conv1"),
        ]

        // Server A + conv1 → c1, c4 in input order (c2 is server B, c3 is conv2).
        XCTAssertEqual(
            clips.matching(serverURL: serverA, destinationKey: "p1/conv1").map(\.id),
            ["c1", "c4"]
        )
        // Server B + conv1 → only c2.
        XCTAssertEqual(
            clips.matching(serverURL: serverB, destinationKey: "p1/conv1").map(\.id),
            ["c2"]
        )
        // Server A + conv2 → only c3.
        XCTAssertEqual(
            clips.matching(serverURL: serverA, destinationKey: "p1/conv2").map(\.id),
            ["c3"]
        )
        // A destination with no clips → empty.
        XCTAssertTrue(
            clips.matching(serverURL: serverB, destinationKey: "p1/conv2").isEmpty
        )
    }
}
