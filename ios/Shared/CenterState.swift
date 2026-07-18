import Foundation

/// The one derivation of "what is Kibo doing right now". The status line,
/// the face expression, and the constellation's animation mode all render
/// this — never a second copy of the priority chain.
///
/// Live interaction (arming, opening the mic, recording) outranks errors on
/// purpose: `WatchStore.errorMessage` is sticky until a clean refresh, and a
/// stale network error must not put a grimace on Kibo mid-recording.
enum CenterState: Equatable {
    case noConversation
    case swipeArmed
    case starting
    case recording
    case error(String)
    case sending
    case thinking
    case loadingReply
    case speaking
    case replyDone
    case needsReview
    /// A server-side failure is showing its amber marker + Retry button;
    /// the face shouldn't grin through it.
    case attention
    case idle(pendingCount: Int, savedCount: Int)

    static func derive(
        hasConversation: Bool,
        swipeArmed: Bool,
        isStarting: Bool,
        isRecording: Bool,
        errorMessage: String?,
        isSending: Bool,
        isThinking: Bool,
        isLoadingReply: Bool,
        isSpeaking: Bool,
        didFinishReply: Bool,
        recoveryItemCount: Int,
        hasRetryableFailure: Bool = false,
        pendingCount: Int,
        savedCount: Int
    ) -> CenterState {
        if swipeArmed { return .swipeArmed }
        if isStarting { return .starting }
        if isRecording { return .recording }
        if isSending { return .sending }
        if isThinking { return .thinking }
        if isLoadingReply { return .loadingReply }
        if isSpeaking { return .speaking }
        if let errorMessage { return .error(errorMessage) }
        if recoveryItemCount > 0 { return .needsReview }
        // `lastFinishedID` is sticky; thoughts that arrived after the reply
        // played (from any device) matter more than the afterglow.
        if didFinishReply && pendingCount == 0 { return .replyDone }
        if hasRetryableFailure { return .attention }
        if !hasConversation { return .noConversation }
        return .idle(pendingCount: pendingCount, savedCount: savedCount)
    }

    /// Structured status: the state-carrying token (if any) plus the
    /// remainder, so presentation code never re-parses a rendered string to
    /// find where the accent color's substring starts.
    var status: StatusContent {
        switch self {
        case .noConversation, .attention:
            StatusContent(accent: nil, text: "")
        case .swipeArmed:
            StatusContent(accent: nil, text: "Release to ask")
        case .starting:
            StatusContent(accent: nil, text: "Opening microphone…")
        case .recording:
            StatusContent(accent: nil, text: "Listening…")
        case let .error(message):
            StatusContent(accent: nil, text: message)
        case .sending:
            StatusContent(accent: nil, text: "Sending…")
        case .thinking:
            StatusContent(accent: nil, text: "Kibo is thinking…")
        case .loadingReply:
            StatusContent(accent: nil, text: "Loading reply…")
        case .speaking:
            StatusContent(accent: nil, text: "Kibo is speaking")
        case .replyDone:
            StatusContent(accent: nil, text: "Reply played")
        case .needsReview:
            StatusContent(accent: nil, text: "Recording needs review")
        case let .idle(pendingCount, savedCount):
            if pendingCount > 0 {
                StatusContent(accent: "\(pendingCount)", text: " pending")
            } else if savedCount > 0 {
                StatusContent(accent: nil, text: "\(savedCount) saved")
            } else {
                StatusContent(accent: nil, text: "")
            }
        }
    }

    /// Derived for a11y + tests — no view builds this string itself.
    var statusLine: String { (status.accent ?? "") + status.text }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Asset name of the face sprite for this state.
    var faceAssetName: String {
        switch self {
        case .noConversation: "face-sleepy"
        case .swipeArmed: "face-excited"
        // Calm ears-up attention: the dashed ring and amplitude ticks say
        // "listening"; the worried-looking wave sprite said "afraid".
        case .starting, .recording: "face-neutral"
        case .error: "face-confused"
        case .sending: "face-content"
        case .thinking: "face-thinking"
        case .loadingReply: "face-content"
        // Open-mouth joy without the baked-in tick doodles — the solid ring
        // and ripples carry "speaking".
        case .speaking: "face-happy"
        // Serene, not "pleased": the pleased sprite's slanted closed eyes
        // read as a scowl at wrist size.
        case .replyDone: "face-serene"
        case .needsReview, .attention: "face-worried"
        case .idle: "face-neutral"
        }
    }

    /// How the constellation animates around the face.
    var constellationMode: ConstellationMode {
        switch self {
        case .swipeArmed, .starting, .recording: .recording
        case .sending, .thinking, .loadingReply: .thinking
        case .speaking: .speaking
        case .replyDone: .afterglow
        case .noConversation, .error, .needsReview, .attention, .idle: .idle
        }
    }
}

/// The state-carrying token of a status line ("3" in "3 pending") plus the
/// remainder, so presentation code never re-parses a rendered string to find
/// where the accent color starts.
struct StatusContent: Equatable {
    var accent: String?
    var text: String
}

enum ConstellationMode: Equatable {
    case idle
    /// Warm fade after a reply finishes playing — the payoff state should
    /// not be the emptiest screen in the flow.
    case afterglow
    case recording
    case thinking
    case speaking
}
