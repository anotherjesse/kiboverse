import Foundation

/// The outcome of one autoplay evaluation, returned as data so both the phone
/// and the watch callers execute the same decision in two lines instead of
/// re-deriving it. `.play` carries the durable speech event that was attempted
/// (for test assertions); `.stopPlayback` fires only when this reply's audio is
/// the one currently active.
enum ReplyPlaybackStep: Equatable {
    /// Wait for more events, already complete, or nothing awaited.
    case none
    /// Start (or restart) playback of this reply's speech.
    case play(turnID: String, destination: KiboDestination, speechEventSeq: UInt64)
    /// The awaited reply failed while its own audio was loading/playing.
    case stopPlayback
}

/// The one awaited reply that may autoplay, plus the fencing and afterglow
/// bookkeeping around it. Shared by `ReplySession` (phone) and `WatchTalkView`;
/// the command-epoch/visibility concerns live separately in `ReplyCommandScope`.
struct ReplyPlaybackIntent: Equatable {
    private(set) var awaitedTurnID: String?
    private(set) var awaitedDestination: KiboDestination?
    private(set) var attemptedSpeechEventSeq: UInt64?
    private(set) var requiredEventsRevision: UInt64?
    /// The awaited reply whose playback actually finished — the afterglow
    /// source. Set only by `advance()`, survives the await-clear completion
    /// performs, and is wiped by `clear()` (selection change / teardown).
    private(set) var finishedTurnID: String?

    mutating func awaitReply(to turnID: String, destination: KiboDestination) {
        awaitedTurnID = turnID
        awaitedDestination = destination
        attemptedSpeechEventSeq = nil
        requiredEventsRevision = nil
    }

    mutating func markPlaybackAttempt(speechEventSeq: UInt64) {
        attemptedSpeechEventSeq = speechEventSeq
    }

    /// Preserve which reply the user asked for, but allow its durable speech
    /// event to start a fresh transport when playback becomes safe again.
    mutating func suspendPlayback() {
        attemptedSpeechEventSeq = nil
    }

    /// Full wipe: forgets the awaited reply, the retry fence, and the
    /// afterglow. Selection change and teardown call this.
    mutating func clear() {
        awaitedTurnID = nil
        awaitedDestination = nil
        attemptedSpeechEventSeq = nil
        requiredEventsRevision = nil
        finishedTurnID = nil
    }

    mutating func retryFinished(
        _ target: RetryTarget,
        outcome: RetryWorkOutcome,
        destination: KiboDestination
    ) {
        guard case let .accepted(requiredEventsRevision) = outcome,
              case let .turn(turnID) = target else { return }
        awaitReply(to: turnID, destination: destination)
        self.requiredEventsRevision = requiredEventsRevision
    }

    /// Evaluate the awaited reply against the latest events and return the
    /// step the caller should execute. Records the playback attempt and the
    /// completion internally; lights the afterglow (`finishedTurnID`) only when
    /// the awaited reply's own audio finished — never on the no-audio
    /// `.complete` path, and never for an unrelated reply the user replayed.
    ///
    /// The retry fence is optional at the seam: it applies only when
    /// `requiredEventsRevision` was set (an accepted turn retry) AND a
    /// revision is supplied. The phone passes nothing and never fences.
    mutating func advance(
        events: [KiboEvent],
        eventsRevision: UInt64? = nil,
        loadingID: String?,
        playingID: String?,
        lastFinishedID: String?
    ) -> ReplyPlaybackStep {
        guard let awaitedTurnID else { return .none }
        if let requiredEventsRevision, let eventsRevision,
           eventsRevision < requiredEventsRevision {
            return .none
        }
        switch events.replyAutoPlayAction(
            for: awaitedTurnID,
            attemptedSpeechEventSeq: attemptedSpeechEventSeq,
            loadingID: loadingID,
            playingID: playingID,
            lastFinishedID: lastFinishedID
        ) {
        case let .startPlayback(speechEventSeq):
            guard let destination = awaitedDestination else { return .none }
            attemptedSpeechEventSeq = speechEventSeq
            return .play(
                turnID: awaitedTurnID,
                destination: destination,
                speechEventSeq: speechEventSeq
            )
        case .complete:
            // Afterglow only when this reply's audio actually played through.
            // `replyAutoPlayAction` also returns `.complete` for replies that
            // carry no speech audio, where `lastFinishedID` can never match.
            if lastFinishedID == PlaybackID.reply(awaitedTurnID) {
                finishedTurnID = awaitedTurnID
            }
            completePlayback()
            return .none
        case .failed:
            let playbackID = PlaybackID.reply(awaitedTurnID)
            let wasActive = loadingID == playbackID || playingID == playbackID
            completePlayback()
            return wasActive ? .stopPlayback : .none
        case .wait:
            return .none
        }
    }

    /// Clear the awaited reply and its fence, but preserve the afterglow set on
    /// the completing tick.
    private mutating func completePlayback() {
        awaitedTurnID = nil
        awaitedDestination = nil
        attemptedSpeechEventSeq = nil
        requiredEventsRevision = nil
    }
}

/// A command's proof that it owns the current epoch and destination. Only a
/// claim the scope still recognizes may finalize an autoplay-arming turn.
struct ReplyCommandClaim: Equatable {
    fileprivate let generation: UUID
    /// The immutable routing target the command must keep using — read by the
    /// caller to submit the turn, so it outlives the current UI selection.
    let destination: KiboDestination
}

/// Owns the view-local command epoch and whether playback is currently allowed
/// (the screen is visible and the scene is active). Teardown transitions
/// invalidate command completions before audio objects publish their own stop
/// notifications.
struct ReplyCommandScope: Equatable {
    private var generation = UUID()
    private(set) var isVisible = false
    private(set) var isActive = false

    var allowsPlayback: Bool { isVisible && isActive }

    mutating func appear(isActive: Bool) {
        generation = UUID()
        isVisible = true
        self.isActive = isActive
    }

    mutating func setActive(_ active: Bool) {
        if isActive && !active { generation = UUID() }
        isActive = active
    }

    mutating func selectionChanged() {
        generation = UUID()
    }

    mutating func disappear() {
        generation = UUID()
        isVisible = false
        isActive = false
    }

    mutating func beginCommand(destination: KiboDestination?) -> ReplyCommandClaim? {
        guard allowsPlayback, let destination else { return nil }
        generation = UUID()
        return ReplyCommandClaim(generation: generation, destination: destination)
    }

    func accepts(_ claim: ReplyCommandClaim, destination: KiboDestination?) -> Bool {
        guard allowsPlayback, claim.generation == generation, let destination else {
            return false
        }
        return claim.destination == destination
    }
}

/// The result of a retry request: `.accepted` carries the events revision the
/// autoplay fence must reach before a retried reply's durable speech may be
/// trusted (a stale poll must not act on the pre-retry failure).
enum RetryWorkOutcome: Equatable {
    case notAccepted
    case accepted(requiredEventsRevision: UInt64)
}
