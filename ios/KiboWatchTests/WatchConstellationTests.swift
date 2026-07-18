import XCTest
@testable import Kibo_Watch

/// The constellation projection and layout: conversation events must render
/// as the spec's marker lifecycle (working → unseen → seen / failed), keep
/// walk order, and land in deterministic positions.
final class WatchConstellationTests: XCTestCase {
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

    private func clip(_ id: String, transcribed: Bool = true) -> [KiboEvent] {
        var events = [event(["kind": "clip", "id": id, "ms": 900, "recorded_at": nextSeq + 1])]
        if transcribed {
            events.append(event(["kind": "transcript", "clip": id, "text": "thought \(id)"]))
        }
        return events
    }

    private func answeredTurn(_ id: String, clips: [String]) -> [KiboEvent] {
        [
            event(["kind": "turn", "id": id, "clips": clips]),
            event(["kind": "reply", "turn": id, "text": "answer \(id)"]),
        ]
    }

    // MARK: - Projection

    /// The spec's canonical cadence: user, user, kibo, user, kibo, user,
    /// user, user — two answered turns, then three unseen thoughts.
    func testCanonicalConversationSequence() {
        var events: [KiboEvent] = []
        events += clip("c1")
        events += clip("c2")
        events += answeredTurn("t1", clips: ["c1", "c2"])
        events += clip("c3")
        events += answeredTurn("t2", clips: ["c3"])
        events += clip("c4")
        events += clip("c5")
        events += clip("c6")

        let markers = events.constellation()
        XCTAssertEqual(
            markers.map(\.id),
            ["c1", "c2", "t1", "c3", "t2", "c4", "c5", "c6"]
        )
        XCTAssertEqual(
            markers.map(\.phase),
            [.seen, .seen, .seen, .seen, .seen, .unseen, .unseen, .unseen]
        )
        XCTAssertEqual(markers[2].kind, .reply)
        XCTAssertEqual(markers[2].contextIDs, ["c1", "c2"])
        XCTAssertEqual(markers[4].contextIDs, ["c3"])
        XCTAssertEqual(markers[5].kind, .voice)
    }

    func testUnclaimedClipLifecycle() {
        var events = clip("c1", transcribed: false)
        XCTAssertEqual(events.constellation().map(\.phase), [.working])

        events.append(event(["kind": "transcript", "clip": "c1", "text": "hi"]))
        XCTAssertEqual(events.constellation().map(\.phase), [.unseen])

        events += [event(["kind": "turn", "id": "t1", "clips": ["c1"]])]
        let markers = events.constellation()
        XCTAssertEqual(markers.map(\.phase), [.seen, .working])
        XCTAssertEqual(markers[1].kind, .reply)
    }

    func testFailedTranscriptIsAmber() {
        var events = clip("c1", transcribed: false)
        events.append(event([
            "kind": "transcript_error", "clip": "c1",
            "error": "no audio", "terminal": true,
        ]))
        XCTAssertEqual(events.constellation().map(\.phase), [.failed])
    }

    func testFailedReplyAndFailedSpeechAreAmber() {
        var events = clip("c1")
        events += [
            event(["kind": "turn", "id": "t1", "clips": ["c1"]]),
            event(["kind": "reply_error", "turn": "t1", "error": "boom", "terminal": true]),
        ]
        XCTAssertEqual(events.constellation().last?.phase, .failed)

        var speechFailed = clip("c2")
        speechFailed += [
            event(["kind": "turn", "id": "t2", "clips": ["c2"]]),
            event(["kind": "reply", "turn": "t2", "text": "ok", "audio": "a.pcm"]),
            event(["kind": "tts_error", "turn": "t2", "error": "no voice", "terminal": true]),
        ]
        XCTAssertEqual(speechFailed.constellation().last?.phase, .failed)
    }

    func testImagesAreDistinctAndFollowClaims() {
        var events: [KiboEvent] = [
            event(["kind": "image", "id": "i1", "recorded_at": 1]),
        ]
        var markers = events.constellation()
        XCTAssertEqual(markers.map(\.kind), [.image])
        XCTAssertEqual(markers.map(\.phase), [.unseen])

        events += [
            event(["kind": "turn", "id": "t1", "images": ["i1"]]),
            event(["kind": "reply", "turn": "t1", "text": "nice photo"]),
        ]
        markers = events.constellation()
        XCTAssertEqual(markers.map(\.phase), [.seen, .seen])
        XCTAssertEqual(markers[1].contextIDs, ["i1"])
    }

    // MARK: - Layout

    func testLayoutIsDeterministic() {
        var events: [KiboEvent] = []
        events += clip("c1")
        events += answeredTurn("t1", clips: ["c1"])
        events += clip("c2")
        let markers = events.constellation()
        XCTAssertEqual(
            ConstellationLayout(markers: markers),
            ConstellationLayout(markers: markers)
        )
    }

    /// A spooled clip's marker id IS the server clip id, so its jitter (and
    /// therefore its position) must not move when the upload lands and the
    /// phase changes.
    func testMarkerPositionSurvivesPhaseChange() {
        let uploading = [ConstellationEvent(
            id: "c1", kind: .voice, phase: .working, contextIDs: []
        )]
        let landed = [ConstellationEvent(
            id: "c1", kind: .voice, phase: .unseen, contextIDs: []
        )]
        let before = ConstellationLayout(markers: uploading).placed[0]
        let after = ConstellationLayout(markers: landed).placed[0]
        XCTAssertEqual(before.angle, after.angle)
        XCTAssertEqual(before.phase, after.phase)
    }

    func testOldHistoryCompresses() {
        var events: [KiboEvent] = []
        for index in 0..<12 {
            events += clip("c\(index)")
            events += answeredTurn("t\(index)", clips: ["c\(index)"])
        }
        let markers = events.constellation()
        XCTAssertEqual(markers.count, 24)
        let layout = ConstellationLayout(markers: markers)
        XCTAssertEqual(layout.placed.count, ConstellationLayout.recentKept)
        XCTAssertEqual(
            layout.compressedCount,
            markers.count - ConstellationLayout.recentKept
        )
        // The newest markers survive compression.
        XCTAssertEqual(layout.placed.last?.event.id, markers.last?.id)
    }

    func testHashIsStableAndSaltSensitive() {
        let first = ConstellationLayout.hash01("clip-abc", salt: 1)
        XCTAssertEqual(first, ConstellationLayout.hash01("clip-abc", salt: 1))
        XCTAssertNotEqual(first, ConstellationLayout.hash01("clip-abc", salt: 2))
        XCTAssertTrue((0.0..<1.0).contains(first))
    }

    // MARK: - Center state

    func testCenterStatePriorities() {
        // Live interaction outranks a sticky error message.
        let recording = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: true, errorMessage: "stale network error",
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 0,
            pendingCount: 0, savedCount: 0
        )
        XCTAssertEqual(recording, .recording)
        XCTAssertEqual(recording.statusLine, "Listening…")

        // Active work also outranks a sticky error; the error resurfaces
        // once nothing is in flight.
        let sending = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: "server unreachable",
            isSending: true, isThinking: true, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 0,
            pendingCount: 0, savedCount: 0
        )
        XCTAssertEqual(sending, .sending)

        let error = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: "server unreachable",
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 0,
            pendingCount: 0, savedCount: 0
        )
        XCTAssertEqual(error, .error("server unreachable"))
        XCTAssertEqual(error.statusLine, "server unreachable")

        // "Reply played" is sticky in the audio layer; a thought that
        // arrived after the reply matters more than the afterglow.
        let playedThenPending = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: nil,
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: true, recoveryItemCount: 0,
            pendingCount: 1, savedCount: 0
        )
        XCTAssertEqual(playedThenPending.statusLine, "1 pending")

        let played = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: nil,
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: true, recoveryItemCount: 0,
            pendingCount: 0, savedCount: 0
        )
        XCTAssertEqual(played, .replyDone)

        let pending = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: nil,
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 0,
            pendingCount: 3, savedCount: 1
        )
        XCTAssertEqual(pending.statusLine, "3 pending")

        let saved = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: nil,
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 0,
            pendingCount: 0, savedCount: 2
        )
        XCTAssertEqual(saved.statusLine, "2 saved")

        let review = CenterState.derive(
            hasConversation: true, swipeArmed: false, isStarting: false,
            isRecording: false, errorMessage: nil,
            isSending: false, isThinking: false, isLoadingReply: false,
            isSpeaking: false, didFinishReply: false, recoveryItemCount: 1,
            pendingCount: 0, savedCount: 1
        )
        XCTAssertEqual(review, .needsReview)
        XCTAssertEqual(review.statusLine, "Recording needs review")
    }
}
