import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// Reply autoplay orchestration shared by the phone (`ReplySession`) and the
/// watch (`WatchTalkView`): the retry-revision fence, command-scope/selection
/// races, suspension re-arm, the returned `ReplyPlaybackStep`, and the
/// session-scoped afterglow. Migrated from WatchAudioTests + KiboAPITests and
/// rewritten against the value-returning `advance()` — no spies, just equality
/// on the returned step and the intent's own state.
final class ReplyOrchestrationTests: XCTestCase {
    private let destination = KiboDestination(
        serverURL: "https://one.example/",
        projectID: "p1",
        conversationID: "c1"
    )
    private let otherServer = KiboDestination(
        serverURL: "https://two.example/",
        projectID: "p1",
        conversationID: "c1"
    )
    private let otherConversation = KiboDestination(
        serverURL: "https://one.example/",
        projectID: "p1",
        conversationID: "c2"
    )

    private func decode(_ json: String) throws -> [KiboEvent] {
        try JSONDecoder().decode([KiboEvent].self, from: Data(json.utf8))
    }

    // A ready reply whose speech is durable-ready at seq 3.
    private let readyReplySpeechReady = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_ready","turn":"t1","attempt":1}]"#
    // A ready reply carrying no speech audio — completes without ever playing.
    private let replyNoAudio = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi"}]"#
    // A ready reply whose speech synthesis terminally failed.
    private let ttsFailed = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"tts_error","turn":"t1","terminal":true,"error":"boom"}]"#
    // The pre-retry terminal reply failure a stale poll would still show.
    private let staleReplyError = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply_error","turn":"t1","terminal":true,"error":"old failure"}]"#

    // MARK: - Retry fencing / ownership

    func testSuccessfulTurnRetryRestoresReplyPlaybackOwnershipBehindFence() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        intent.markPlaybackAttempt(speechEventSeq: 3)
        intent.clear()
        XCTAssertNil(intent.awaitedTurnID)

        intent.retryFinished(
            .turn("t1"),
            outcome: .accepted(requiredEventsRevision: 4),
            destination: destination
        )
        XCTAssertEqual(intent.awaitedTurnID, "t1")
        XCTAssertNil(intent.attemptedSpeechEventSeq)

        // Below the required revision the fence holds — no evaluation, the
        // reply stays awaited.
        XCTAssertEqual(
            intent.advance(events: events, eventsRevision: 3, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        XCTAssertEqual(intent.awaitedTurnID, "t1")

        // At the required revision the fence lifts and the retried reply plays.
        XCTAssertEqual(
            intent.advance(events: events, eventsRevision: 4, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .play(turnID: "t1", destination: destination, speechEventSeq: 3)
        )
    }

    func testAcceptedRetryWaitsForRequiredDurableRefresh() throws {
        let staleEvents = try decode(staleReplyError)
        var intent = ReplyPlaybackIntent()
        intent.retryFinished(
            .turn("t1"),
            outcome: .accepted(requiredEventsRevision: 7),
            destination: destination
        )
        XCTAssertEqual(intent.awaitedTurnID, "t1")

        // The stale terminal failure below the fence must not be acted on.
        XCTAssertEqual(
            intent.advance(events: staleEvents, eventsRevision: 6, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        XCTAssertEqual(intent.awaitedTurnID, "t1")

        // At the required revision the fence lifts and the failure is consumed.
        XCTAssertEqual(
            intent.advance(events: staleEvents, eventsRevision: 7, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        XCTAssertNil(intent.awaitedTurnID)
    }

    func testRejectedOrClipRetryDoesNotClaimReplyPlayback() {
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "old-turn", destination: destination)
        intent.markPlaybackAttempt(speechEventSeq: 3)
        intent.clear()

        intent.retryFinished(.turn("t1"), outcome: .notAccepted, destination: destination)
        XCTAssertNil(intent.awaitedTurnID)

        intent.retryFinished(
            .clip("c1"),
            outcome: .accepted(requiredEventsRevision: 1),
            destination: destination
        )
        XCTAssertNil(intent.awaitedTurnID)
    }

    func testNilEventsRevisionLeavesRetryFenceInert() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.retryFinished(
            .turn("t1"),
            outcome: .accepted(requiredEventsRevision: 7),
            destination: destination
        )
        // The phone supplies no revision: the fence never blocks even though
        // `requiredEventsRevision` is set, so the reply plays immediately.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .play(turnID: "t1", destination: destination, speechEventSeq: 3)
        )
    }

    // MARK: - Command scope / selection races

    func testReplyCommandScopeRejectsSelectionAndViewLifetimeRaces() {
        var scope = ReplyCommandScope()
        scope.appear(isActive: true)
        let claim = scope.beginCommand(destination: destination)!

        XCTAssertTrue(scope.accepts(claim, destination: destination))
        XCTAssertFalse(scope.accepts(claim, destination: otherServer))
        XCTAssertFalse(scope.accepts(claim, destination: otherConversation))

        scope.selectionChanged()
        XCTAssertFalse(scope.accepts(claim, destination: destination))

        let replacement = scope.beginCommand(destination: destination)!
        scope.disappear()
        XCTAssertFalse(scope.accepts(replacement, destination: destination))
    }

    func testNewCommandAndInactiveSceneInvalidateEarlierClaims() {
        var scope = ReplyCommandScope()
        scope.appear(isActive: true)
        let first = scope.beginCommand(destination: destination)!
        let second = scope.beginCommand(destination: destination)!

        XCTAssertFalse(scope.accepts(first, destination: destination))
        XCTAssertTrue(scope.accepts(second, destination: destination))

        scope.setActive(false)
        XCTAssertFalse(scope.accepts(second, destination: destination))
        XCTAssertFalse(scope.allowsPlayback)

        scope.setActive(true)
        XCTAssertTrue(scope.allowsPlayback)
        XCTAssertFalse(scope.accepts(second, destination: destination))
    }

    func testScopeRejectsCommandsWithoutVisibilityOrDestination() {
        var scope = ReplyCommandScope()
        // Not visible yet: no command.
        XCTAssertNil(scope.beginCommand(destination: destination))
        scope.appear(isActive: true)
        // Visible + active but nothing selected: no command.
        XCTAssertNil(scope.beginCommand(destination: nil))
        let claim = scope.beginCommand(destination: destination)!
        // A nil destination never satisfies acceptance.
        XCTAssertFalse(scope.accepts(claim, destination: nil))
    }

    func testScopeAndIntentInvalidateBeforeEveryTeardown() {
        var scope = ReplyCommandScope()
        var intent = ReplyPlaybackIntent()
        scope.appear(isActive: true)
        let first = scope.beginCommand(destination: destination)!
        let replacement = scope.beginCommand(destination: destination)!
        XCTAssertFalse(scope.accepts(first, destination: destination))
        XCTAssertTrue(scope.accepts(replacement, destination: destination))

        intent.awaitReply(to: "turn-1", destination: destination)
        intent.markPlaybackAttempt(speechEventSeq: 7)
        // Scene inactive: the scope invalidates the claim; the intent suspends
        // (keeps the awaited reply, re-arms its durable speech event).
        scope.setActive(false)
        intent.suspendPlayback()
        XCTAssertFalse(scope.accepts(replacement, destination: destination))
        XCTAssertEqual(intent.awaitedTurnID, "turn-1")
        XCTAssertNil(intent.attemptedSpeechEventSeq)
        XCTAssertFalse(scope.allowsPlayback)

        scope.setActive(true)
        let foreground = scope.beginCommand(destination: destination)!
        // Selection change wipes both the claim and the awaited reply.
        scope.selectionChanged()
        intent.clear()
        XCTAssertFalse(scope.accepts(foreground, destination: destination))
        XCTAssertNil(intent.awaitedTurnID)

        scope.disappear()
        XCTAssertFalse(scope.allowsPlayback)
        XCTAssertNil(scope.beginCommand(destination: destination))
    }

    // MARK: - Suspension / autoplay spine

    func testSuspendedReadyReplyReopensTheSamePlaybackAttempt() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)

        // advance records the attempt internally.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .play(turnID: "t1", destination: destination, speechEventSeq: 3)
        )
        // A second pass waits — the same durable event is already attempted.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        // Suspension re-arms the same durable speech event.
        intent.suspendPlayback()
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .play(turnID: "t1", destination: destination, speechEventSeq: 3)
        )
    }

    func testSharedAutoplayWaitsForSpeechStartedAndThroughTooEarlyLoadingGap() throws {
        let reply = try decode(#"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"}]"#)
        XCTAssertEqual(reply.replyReadiness(for: "t1"), .waiting)

        let started = try decode(#"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}]"#)
        XCTAssertEqual(started.replyReadiness(for: "t1"), .playable)
        XCTAssertEqual(
            started.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: "reply-t1", playingID: nil, lastFinishedID: nil
            ),
            .wait
        )

        let restarted = try decode(#"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1},{"seq":4,"kind":"speech_retry_scheduled","turn":"t1","attempt":1},{"seq":5,"kind":"speech_started","turn":"t1","attempt":2}]"#)
        XCTAssertEqual(
            restarted.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: nil, playingID: nil, lastFinishedID: nil
            ),
            .startPlayback(speechEventSeq: 5)
        )
    }

    // MARK: - Failed step

    func testFailedReplyStopsItsOwnActivePlayback() throws {
        let events = try decode(ttsFailed)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        // The reply's audio is currently loading: the failure must stop it.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: PlaybackID.reply("t1"), playingID: nil, lastFinishedID: nil),
            .stopPlayback
        )
        XCTAssertNil(intent.awaitedTurnID)
        XCTAssertNil(intent.finishedTurnID)
    }

    func testFailedReplyWithoutActivePlaybackDoesNotStop() throws {
        let events = try decode(ttsFailed)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        // No audio for this reply is active: nothing to stop, just give up.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        XCTAssertNil(intent.awaitedTurnID)
    }

    // MARK: - Session-scoped afterglow

    func testAwaitedReplyCompletionLightsAfterglow() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        // The reply's speech played to the end: lastFinishedID matches.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: PlaybackID.reply("t1")),
            .none
        )
        XCTAssertEqual(intent.finishedTurnID, "t1")
        // Completion clears the await but the afterglow survives.
        XCTAssertNil(intent.awaitedTurnID)
    }

    func testNoAudioReplyCompletionDoesNotLightAfterglow() throws {
        let events = try decode(replyNoAudio)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        // `replyAutoPlayAction` returns `.complete` for a silent reply too;
        // nothing ever finished playing, so no glow.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: nil),
            .none
        )
        XCTAssertNil(intent.finishedTurnID)
        XCTAssertNil(intent.awaitedTurnID)
    }

    func testUnrelatedFinishedPlaybackDoesNotLightAfterglow() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        // The user manually replayed a *different* reply from the timeline:
        // its finish must not glow the awaited reply, which still wants to play.
        XCTAssertEqual(
            intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: PlaybackID.reply("t99")),
            .play(turnID: "t1", destination: destination, speechEventSeq: 3)
        )
        XCTAssertNil(intent.finishedTurnID)
    }

    func testFinishedPlaybackWithNothingAwaitedNeverGlows() {
        var intent = ReplyPlaybackIntent()
        // A stray finished-playback signal (an old reply replayed) with nothing
        // awaited: the phone's semantic fix — no false afterglow.
        XCTAssertEqual(
            intent.advance(events: [], loadingID: nil, playingID: nil, lastFinishedID: PlaybackID.reply("t99")),
            .none
        )
        XCTAssertNil(intent.finishedTurnID)
    }

    func testClearWipesAfterglow() throws {
        let events = try decode(readyReplySpeechReady)
        var intent = ReplyPlaybackIntent()
        intent.awaitReply(to: "t1", destination: destination)
        _ = intent.advance(events: events, loadingID: nil, playingID: nil, lastFinishedID: PlaybackID.reply("t1"))
        XCTAssertEqual(intent.finishedTurnID, "t1")
        // Selection change / teardown wipes the afterglow.
        intent.clear()
        XCTAssertNil(intent.finishedTurnID)
    }
}
