import Foundation

/// The phone's input mapping into the shared `CenterState`. This is binding,
/// not logic: the priority chain, copy, face sprites, and constellation modes
/// all live once in `CenterState`; the watch has its own `derive` call
/// (`WatchTalkView`) with its own store/audio shapes.
///
/// Two phone-specific bindings the plan pins (§2.1):
/// - `isStarting: audio.isStarting || audio.isHolding` — `beginHold()` sets
///   the hold synchronously, but the recorder's `isStarting` only publishes
///   after async session activation. Without the disjunction the rebuilt
///   phone would sit visually idle under the user's finger, regressing
///   today's shipped "Listening…"-on-touch.
/// - `didFinishReply: session.intent.finishedTurnID != nil` — the afterglow
///   celebrates the awaited fresh reply only. Manually replaying an old reply
///   from the timeline sets `audio.lastFinishedID` but never `finishedTurnID`,
///   so no false `.replyDone`.
extension CenterState {
    /// The phone input mapping as a pure function of plain values — the
    /// testable core the `@MainActor` convenience wrapper delegates to. Split
    /// out so the phone-specific bindings (the `isStarting || isHolding`
    /// disjunction, the recording → playback → store error precedence, the
    /// reply-only playback filter) can be unit-tested without constructing an
    /// `AppStore`/`AudioCoordinator`/`ReplySession`.
    static func derivePhone(
        hasConversation: Bool,
        swipeArmed: Bool,
        audioIsStarting: Bool,
        audioIsHolding: Bool,
        audioIsRecording: Bool,
        recordingErrorMessage: String?,
        playbackErrorMessage: String?,
        storeErrorMessage: String?,
        isUploading: Bool,
        isAskingKibo: Bool,
        loadingID: String?,
        playingID: String?,
        finishedTurnID: String?,
        recoveryItemCount: Int,
        hasRetryableFailure: Bool,
        pendingCount: Int,
        savedCount: Int
    ) -> CenterState {
        derive(
            hasConversation: hasConversation,
            swipeArmed: swipeArmed,
            isStarting: audioIsStarting || audioIsHolding,
            isRecording: audioIsRecording,
            // Same source order as the old statusLine chain: a recording
            // error, then a playback error, then a store error.
            errorMessage: recordingErrorMessage
                ?? playbackErrorMessage
                ?? storeErrorMessage,
            isSending: isUploading,
            isThinking: isAskingKibo,
            // The phone plays recorded clips too, so filter loading/speaking
            // through PlaybackID.isReply — a clip playing is not a reply.
            isLoadingReply: PlaybackID.isReply(loadingID),
            isSpeaking: PlaybackID.isReply(playingID),
            didFinishReply: finishedTurnID != nil,
            recoveryItemCount: recoveryItemCount,
            hasRetryableFailure: hasRetryableFailure,
            pendingCount: pendingCount,
            savedCount: savedCount
        )
    }

    @MainActor
    static func derive(
        store: AppStore,
        audio: AudioCoordinator,
        session: ReplySession,
        swipeArmed: Bool
    ) -> CenterState {
        derivePhone(
            hasConversation: store.selectedConversationID != nil,
            swipeArmed: swipeArmed,
            audioIsStarting: audio.isStarting,
            audioIsHolding: audio.isHolding,
            audioIsRecording: audio.isRecording,
            recordingErrorMessage: audio.recordingErrorMessage,
            playbackErrorMessage: audio.playbackErrorMessage,
            storeErrorMessage: store.errorMessage,
            isUploading: store.isUploading,
            isAskingKibo: store.isAskingKibo,
            loadingID: audio.loadingID,
            playingID: audio.playingID,
            finishedTurnID: session.intent.finishedTurnID,
            recoveryItemCount: store.recoveryItemCount,
            hasRetryableFailure: store.events.retryableFailure != nil,
            pendingCount: store.askableItemCount,
            savedCount: store.pendingUploadCount
        )
    }
}
