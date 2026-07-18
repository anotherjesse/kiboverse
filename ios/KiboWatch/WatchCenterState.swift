import Foundation

/// The one derivation of "what is Kibo doing right now". The status line,
/// the face expression, and the constellation's animation mode all render
/// this — never a second copy of the priority chain.
///
/// Live interaction (arming, opening the mic, recording) outranks errors on
/// purpose: `WatchStore.errorMessage` is sticky until a clean refresh, and a
/// stale network error must not put a grimace on Kibo mid-recording.
enum WatchCenterState: Equatable {
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
    ) -> WatchCenterState {
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

    /// Dynamic states only — no persistent instructional copy.
    var statusLine: String {
        switch self {
        case .noConversation: ""
        case .swipeArmed: "Release to ask"
        case .starting: "Opening microphone…"
        case .recording: "Listening…"
        case let .error(message): message
        case .sending: "Sending…"
        case .thinking: "Kibo is thinking…"
        case .loadingReply: "Loading reply…"
        case .speaking: "Kibo is speaking"
        case .replyDone: "Reply played"
        case .needsReview: "Recording needs review"
        case .attention: ""
        case let .idle(pendingCount, savedCount):
            if pendingCount > 0 { "\(pendingCount) pending" }
            else if savedCount > 0 { "Saved on watch" }
            else { "" }
        }
    }

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
    var constellationMode: WatchConstellationMode {
        switch self {
        case .swipeArmed, .starting, .recording: .recording
        case .sending, .thinking, .loadingReply: .thinking
        case .speaking: .speaking
        case .replyDone: .afterglow
        case .noConversation, .error, .needsReview, .attention, .idle: .idle
        }
    }
}

enum WatchConstellationMode: Equatable {
    case idle
    /// Warm fade after a reply finishes playing — the payoff state should
    /// not be the emptiest screen in the flow.
    case afterglow
    case recording
    case thinking
    case speaking
}
