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
    @MainActor
    static func derive(
        store: AppStore,
        audio: AudioCoordinator,
        session: ReplySession,
        swipeArmed: Bool
    ) -> CenterState {
        derive(
            hasConversation: store.selectedConversationID != nil,
            swipeArmed: swipeArmed,
            isStarting: audio.isStarting || audio.isHolding,
            isRecording: audio.isRecording,
            // Same source order as the old statusLine chain: a recording
            // error, then a playback error, then a store error.
            errorMessage: audio.recordingErrorMessage
                ?? audio.playbackErrorMessage
                ?? store.errorMessage,
            isSending: store.isUploading,
            isThinking: store.isAskingKibo,
            // The phone plays recorded clips too, so filter loading/speaking
            // through PlaybackID.isReply — a clip playing is not a reply.
            isLoadingReply: PlaybackID.isReply(audio.loadingID),
            isSpeaking: PlaybackID.isReply(audio.playingID),
            didFinishReply: session.intent.finishedTurnID != nil,
            recoveryItemCount: store.recoveryItemCount,
            hasRetryableFailure: store.events.retryableFailure != nil,
            pendingCount: store.askableItemCount,
            savedCount: store.pendingUploadCount
        )
    }
}
