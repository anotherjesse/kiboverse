import XCTest
@testable import Kibo

/// The phone's `CenterState` input mapping. Exercises the pure `derivePhone`
/// core (the plain-value split of `derive(store:audio:session:swipeArmed:)`)
/// so the phone-specific bindings are locked without constructing an
/// `AppStore`/`AudioCoordinator`/`ReplySession`.
final class CenterStatePhoneTests: XCTestCase {
    /// All-quiet inputs; each test overrides only what it exercises.
    private func derive(
        hasConversation: Bool = true,
        swipeArmed: Bool = false,
        audioIsStarting: Bool = false,
        audioIsHolding: Bool = false,
        audioIsRecording: Bool = false,
        recordingErrorMessage: String? = nil,
        playbackErrorMessage: String? = nil,
        storeErrorMessage: String? = nil,
        isUploading: Bool = false,
        isAskingKibo: Bool = false,
        loadingID: String? = nil,
        playingID: String? = nil,
        finishedTurnID: String? = nil,
        recoveryItemCount: Int = 0,
        hasRetryableFailure: Bool = false,
        pendingCount: Int = 0,
        savedCount: Int = 0
    ) -> CenterState {
        CenterState.derivePhone(
            hasConversation: hasConversation,
            swipeArmed: swipeArmed,
            audioIsStarting: audioIsStarting,
            audioIsHolding: audioIsHolding,
            audioIsRecording: audioIsRecording,
            recordingErrorMessage: recordingErrorMessage,
            playbackErrorMessage: playbackErrorMessage,
            storeErrorMessage: storeErrorMessage,
            isUploading: isUploading,
            isAskingKibo: isAskingKibo,
            loadingID: loadingID,
            playingID: playingID,
            finishedTurnID: finishedTurnID,
            recoveryItemCount: recoveryItemCount,
            hasRetryableFailure: hasRetryableFailure,
            pendingCount: pendingCount,
            savedCount: savedCount
        )
    }

    func testAskingKiboIsThinking() {
        XCTAssertEqual(derive(isAskingKibo: true), .thinking)
    }

    func testUploadingIsSending() {
        XCTAssertEqual(derive(isUploading: true), .sending)
    }

    /// `beginHold()` sets the hold synchronously; the recorder's `isStarting`
    /// only publishes after async session activation. The disjunction keeps
    /// Kibo visually "Opening microphone…" under the finger either way.
    func testHoldingIsStarting() {
        XCTAssertEqual(derive(audioIsHolding: true), .starting)
        XCTAssertEqual(derive(audioIsStarting: true), .starting)
    }

    /// A recording error outranks a playback error outranks a store error —
    /// the same source order as the old statusLine chain.
    func testErrorPrecedenceRecordingThenPlaybackThenStore() {
        XCTAssertEqual(
            derive(
                recordingErrorMessage: "mic denied",
                playbackErrorMessage: "no voice",
                storeErrorMessage: "server unreachable"
            ),
            .error("mic denied")
        )
        XCTAssertEqual(
            derive(playbackErrorMessage: "no voice", storeErrorMessage: "server unreachable"),
            .error("no voice")
        )
        XCTAssertEqual(
            derive(storeErrorMessage: "server unreachable"),
            .error("server unreachable")
        )
    }

    /// A clip playing is not a reply — loading/speaking derive only from a
    /// reply-tagged playback id.
    func testReplyOnlyPlaybackFilter() {
        XCTAssertEqual(derive(loadingID: PlaybackID.clip("c1")), .idle(pendingCount: 0, savedCount: 0))
        XCTAssertEqual(derive(loadingID: PlaybackID.reply("t1")), .loadingReply)
        XCTAssertEqual(derive(playingID: PlaybackID.clip("c1")), .idle(pendingCount: 0, savedCount: 0))
        XCTAssertEqual(derive(playingID: PlaybackID.reply("t1")), .speaking)
    }

    /// The armed swipe is the loudest interaction: it wins over recording,
    /// sending, thinking, playback, errors, recovery, and pending counts.
    func testSwipeArmedWinsOverEverything() {
        XCTAssertEqual(
            derive(
                swipeArmed: true,
                audioIsStarting: true,
                audioIsHolding: true,
                audioIsRecording: true,
                recordingErrorMessage: "mic denied",
                playbackErrorMessage: "no voice",
                storeErrorMessage: "server unreachable",
                isUploading: true,
                isAskingKibo: true,
                loadingID: PlaybackID.reply("t1"),
                playingID: PlaybackID.reply("t1"),
                finishedTurnID: "t1",
                recoveryItemCount: 3,
                hasRetryableFailure: true,
                pendingCount: 5,
                savedCount: 2
            ),
            .swipeArmed
        )
    }
}
