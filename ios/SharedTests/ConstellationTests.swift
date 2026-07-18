import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// The constellation projection and layout: conversation events must render
/// as the spec's marker lifecycle (working → unseen → seen / failed), keep
/// walk order, and land in deterministic positions.
final class ConstellationTests: XCTestCase {
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

    private var watchMetrics: ConstellationLayoutMetrics { ConstellationStyle.watch.layout }

    func testLayoutIsDeterministic() {
        var events: [KiboEvent] = []
        events += clip("c1")
        events += answeredTurn("t1", clips: ["c1"])
        events += clip("c2")
        let markers = events.constellation()
        XCTAssertEqual(
            ConstellationLayout(markers: markers, metrics: watchMetrics),
            ConstellationLayout(markers: markers, metrics: watchMetrics)
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
        let before = ConstellationLayout(markers: uploading, metrics: watchMetrics).placed[0]
        let after = ConstellationLayout(markers: landed, metrics: watchMetrics).placed[0]
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
        let layout = ConstellationLayout(markers: markers, metrics: watchMetrics)
        XCTAssertEqual(layout.placed.count, watchMetrics.recentKept)
        XCTAssertEqual(
            layout.compressedCount,
            markers.count - watchMetrics.recentKept
        )
        // The newest markers survive compression.
        XCTAssertEqual(layout.placed.last?.event.id, markers.last?.id)
    }

    /// Layout geometry is keyed on the metrics: the phone's larger keep-count
    /// leaves the same 24-event history uncompressed where the watch trims it.
    func testCompressionFollowsMetrics() {
        var events: [KiboEvent] = []
        for index in 0..<12 {
            events += clip("c\(index)")
            events += answeredTurn("t\(index)", clips: ["c\(index)"])
        }
        let markers = events.constellation()
        XCTAssertEqual(markers.count, 24)

        // Watch: 24 > 14, so compress to the 12 most recent.
        let watch = ConstellationLayout(markers: markers, metrics: ConstellationStyle.watch.layout)
        XCTAssertEqual(watch.placed.count, 12)
        XCTAssertEqual(watch.compressedCount, 12)

        // Phone: 24 > 22, so compress to the 18 most recent.
        let phone = ConstellationLayout(markers: markers, metrics: ConstellationStyle.phone.layout)
        XCTAssertEqual(phone.placed.count, 18)
        XCTAssertEqual(phone.compressedCount, 6)
    }

    func testHashIsStableAndSaltSensitive() {
        let first = ConstellationLayout.hash01("clip-abc", salt: 1)
        XCTAssertEqual(first, ConstellationLayout.hash01("clip-abc", salt: 1))
        XCTAssertNotEqual(first, ConstellationLayout.hash01("clip-abc", salt: 2))
        XCTAssertTrue((0.0..<1.0).contains(first))
    }

    // MARK: - Style

    /// The watch frame pacing must match the historical per-mode intervals
    /// verbatim — the battery contract the cadence check gates.
    func testFramePacingWatchMatchesHistoricalIntervals() {
        let pacing = FramePacing.watch
        XCTAssertEqual(pacing.interval(for: .idle), 1.0 / 8.0)
        XCTAssertEqual(pacing.interval(for: .afterglow), 1.0 / 10.0)
        XCTAssertEqual(pacing.interval(for: .thinking), 1.0 / 15.0)
        XCTAssertEqual(pacing.interval(for: .recording), 1.0 / 30.0)
        XCTAssertEqual(pacing.interval(for: .speaking), 1.0 / 30.0)
    }

    /// At `dustDepthStrength` 0 (the watch preset) both dust factors multiply
    /// by exactly 1.0 for every depth — the guarantee that the watch's star
    /// dust is byte-identical after the style split.
    func testDustDepthStrengthZeroIsIdentity() {
        let style = ConstellationStyle.watch
        XCTAssertEqual(style.dustDepthStrength, 0)
        for depth in [0.0, 0.13, 0.5, 0.87, 1.0] {
            XCTAssertEqual(style.dustOpacityFactor(depth: depth), 1.0)
            XCTAssertEqual(style.dustSpeedFactor(depth: depth), 1.0)
        }
        // And the phone preset genuinely attenuates, so the seam isn't a no-op.
        XCTAssertLessThan(ConstellationStyle.phone.dustOpacityFactor(depth: 1.0), 1.0)
        XCTAssertLessThan(ConstellationStyle.phone.dustSpeedFactor(depth: 1.0), 1.0)
    }

    /// The iPad/Mac seam picks the watch look below 260pt and the phone look
    /// at and above it.
    func testFittingBoundaryAt260() {
        XCTAssertEqual(ConstellationStyle.fitting(minDimension: 259), .watch)
        XCTAssertEqual(ConstellationStyle.fitting(minDimension: 260), .phone)
        XCTAssertEqual(ConstellationStyle.fitting(minDimension: 261), .phone)
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
