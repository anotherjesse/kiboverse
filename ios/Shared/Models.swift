import Foundation

enum ProjectSelection {
    static func preferred(in projects: [KiboProject], savedID: String?) -> KiboProject? {
        projects.first { $0.id == savedID } ?? projects.first
    }
}

struct TimelineItem: Identifiable, Hashable {
    enum Role: Hashable { case person, kibo, status, error }
    let id: String
    let role: Role
    let title: String
    let body: String
    let turnID: String?
    let clipID: String?
    let durationMs: UInt64?
    let canPlay: Bool
    let retryTarget: RetryTarget?
    let imageID: String?
    let imageSHA256: String?
    let imageAspectRatio: Double?

    init(
        id: String,
        role: Role,
        title: String,
        body: String,
        turnID: String?,
        clipID: String?,
        durationMs: UInt64?,
        canPlay: Bool,
        retryTarget: RetryTarget?,
        imageID: String? = nil,
        imageSHA256: String? = nil,
        imageAspectRatio: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.turnID = turnID
        self.clipID = clipID
        self.durationMs = durationMs
        self.canPlay = canPlay
        self.retryTarget = retryTarget
        self.imageID = imageID
        self.imageSHA256 = imageSHA256
        self.imageAspectRatio = imageAspectRatio
    }
}

enum RetryTarget: Hashable {
    case clip(String)
    case turn(String)
}

/// One clip or image in conversation order — the unit both the timeline and
/// the constellation render.
struct ConversationMedia: Hashable {
    let id: String
    let isImage: Bool
}

/// The conversation in presentation order: each turn with its claimed media
/// (merge-sorted by recorded-at), then the unclaimed tail the next "Ask Kibo"
/// would submit, in the order the server will claim it.
struct ConversationWalk {
    struct Turn {
        let turnID: String
        let media: [ConversationMedia]
    }

    let turns: [Turn]
    let unclaimed: [ConversationMedia]
}

/// A single conversation event as the watch constellation renders it: who it
/// belongs to, and where it sits in the seen/unseen/working/failed lifecycle.
struct ConstellationEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case voice
        case image
        case reply
    }

    enum Phase: Hashable {
        /// Upload, transcription, thinking, or speech still in flight.
        case working
        /// Transcribed but not yet included in any Ask Kibo request.
        case unseen
        /// Part of Kibo's context (media) or a completed reply.
        case seen
        /// Terminal failure needing attention.
        case failed
    }

    /// Clip/image/turn ID. Watch-spooled clips keep their spool ID as the
    /// server clip ID, so a marker's identity survives the upload transition.
    let id: String
    let kind: Kind
    let phase: Phase
    /// For replies: the media IDs this response consumed.
    let contextIDs: [String]
}

extension Array where Element == KiboEvent {
    var pendingTurnIDs: Set<String> {
        let projection = ConversationPresentation(events: self)
        return projection.turnIDs.filter { turnID in
            switch projection.replies[turnID] {
            case .ready, .failed: false
            case .thinking, .retrying, nil: true
            }
        }
    }

    /// True while kibod is producing something this device is waiting on —
    /// a reply still thinking/retrying, or reply speech not yet terminal.
    /// Unclaimed-clip transcription is excluded: it drives no wrist-visible
    /// state, so it never justifies the fast poll cadence.
    var needsFastPolling: Bool {
        let projection = ConversationPresentation(events: self)
        for turnID in projection.turnIDs {
            switch projection.replies[turnID] {
            case .thinking, .retrying, nil:
                return true
            case .failed:
                continue
            case let .ready(reply):
                guard reply.audio != nil else { continue }
                switch projection.speech[turnID] {
                case .streaming, .retrying, nil:
                    return true
                case .ready, .failed:
                    continue
                }
            }
        }
        return false
    }

    /// Server-side clips not yet claimed by any turn — the recordings the
    /// next "Ask Kibo" would submit. Mirrors `pendingTurnIDs`.
    var unclaimedClipIDs: Set<String> {
        Set(ConversationPresentation(events: self).walk().unclaimed
            .lazy.filter { !$0.isImage }.map(\.id))
    }

    var unclaimedClipCount: Int { unclaimedClipIDs.count }

    /// Server-side images not yet claimed by any turn. Together with
    /// `unclaimedClipIDs` this is everything the next "Ask Kibo" would submit.
    var unclaimedImageIDs: Set<String> {
        Set(ConversationPresentation(events: self).walk().unclaimed
            .lazy.filter(\.isImage).map(\.id))
    }

    var unclaimedMediaCount: Int {
        Set(ConversationPresentation(events: self).walk().unclaimed).count
    }

    func timeline() -> [TimelineItem] {
        let projection = ConversationPresentation(events: self)
        let walk = projection.walk()
        var result: [TimelineItem] = []

        func personCard(clipID: String, title: String) -> TimelineItem {
            let (body, retryTarget): (String, RetryTarget?) = switch projection.transcripts[clipID] {
            case let .ready(text): (text, nil)
            case let .failed(message): (message, .clip(clipID))
            case .retrying: ("Retrying transcription…", nil)
            case .transcribing, nil: ("Transcribing…", nil)
            }
            return TimelineItem(
                id: "clip-\(clipID)", role: .person, title: title,
                body: body, turnID: nil, clipID: clipID,
                durationMs: projection.durations[clipID], canPlay: true,
                retryTarget: retryTarget
            )
        }

        func imageCard(imageID: String, title: String) -> TimelineItem {
            let event = projection.imageEvents[imageID]
            let aspectRatio: Double? = {
                guard let width = event?.width, let height = event?.height,
                      width > 0, height > 0 else { return nil }
                return Double(width) / Double(height)
            }()
            return TimelineItem(
                id: "image-\(imageID)", role: .person, title: title,
                body: event?.caption ?? "", turnID: nil, clipID: nil,
                durationMs: nil, canPlay: false, retryTarget: nil,
                imageID: imageID, imageSHA256: event?.sha256,
                imageAspectRatio: aspectRatio
            )
        }

        for turn in walk.turns {
            let turnID = turn.turnID
            for item in turn.media {
                result.append(item.isImage
                    ? imageCard(imageID: item.id, title: "You")
                    : personCard(clipID: item.id, title: "You"))
            }
            switch projection.replies[turnID] {
            case let .ready(reply):
                let speechDetail: String? = switch projection.speech[turnID] {
                case let .failed(message): "Speech unavailable: \(message)"
                case .retrying, .streaming(isRetry: true): "Retrying speech…"
                case .streaming(isRetry: false), .ready, nil: nil
                }
                let canPlay = reply.audio != nil
                    && projection.speech[turnID]?.permitsPlayback == true
                result.append(TimelineItem(
                    id: "kibo-\(turnID)", role: .kibo, title: "Kibo",
                    body: [reply.text ?? "Reply ready", speechDetail]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                    turnID: turnID, clipID: nil, durationMs: nil,
                    canPlay: canPlay,
                    retryTarget: projection.speech[turnID]?.isFailed == true ? .turn(turnID) : nil
                ))
            case let .failed(error, _):
                result.append(TimelineItem(
                    id: "error-\(turnID)", role: .error, title: "Reply failed",
                    body: error, turnID: nil, clipID: nil, durationMs: nil, canPlay: false,
                    retryTarget: .turn(turnID)
                ))
            case .retrying:
                result.append(TimelineItem(
                    id: "status-\(turnID)", role: .status, title: "Kibo",
                    body: "Retrying…", turnID: nil, clipID: nil, durationMs: nil, canPlay: false,
                    retryTarget: nil
                ))
            case .thinking, nil:
                result.append(TimelineItem(
                    id: "status-\(turnID)", role: .status, title: "Kibo",
                    body: "Thinking…", turnID: nil, clipID: nil, durationMs: nil, canPlay: false,
                    retryTarget: nil
                ))
            }
        }

        for item in walk.unclaimed {
            result.append(item.isImage
                ? imageCard(imageID: item.id, title: "You · not asked yet")
                : personCard(clipID: item.id, title: "You · not asked yet"))
        }
        return result
    }

    /// The conversation as the watch constellation renders it: one marker per
    /// media item and reply, in walk order (turns oldest-first, then the
    /// unclaimed tail — the thoughts Kibo hasn't seen yet).
    func constellation() -> [ConstellationEvent] {
        let projection = ConversationPresentation(events: self)
        let walk = projection.walk()
        var result: [ConstellationEvent] = []
        for turn in walk.turns {
            for item in turn.media {
                result.append(ConstellationEvent(
                    id: item.id,
                    kind: item.isImage ? .image : .voice,
                    phase: .seen,
                    contextIDs: []
                ))
            }
            let phase: ConstellationEvent.Phase = switch projection.replies[turn.turnID] {
            case .ready:
                projection.speech[turn.turnID]?.isFailed == true ? .failed : .seen
            case .failed: .failed
            case .thinking, .retrying, nil: .working
            }
            result.append(ConstellationEvent(
                id: turn.turnID,
                kind: .reply,
                phase: phase,
                contextIDs: turn.media.map(\.id)
            ))
        }
        for item in walk.unclaimed {
            let phase: ConstellationEvent.Phase
            if item.isImage {
                phase = .unseen
            } else {
                phase = switch projection.transcripts[item.id] {
                case .ready, nil: .unseen
                case .transcribing, .retrying: .working
                case .failed: .failed
                }
            }
            result.append(ConstellationEvent(
                id: item.id,
                kind: item.isImage ? .image : .voice,
                phase: phase,
                contextIDs: []
            ))
        }
        return result
    }

    var retryableFailure: RetryTarget? {
        timeline().reversed().compactMap(\.retryTarget).first
    }

    func replyReadiness(for turnID: String) -> ReplyReadiness {
        let projection = ConversationPresentation(events: self)
        switch projection.replies[turnID] {
        case let .ready(reply):
            guard reply.audio != nil else { return .failed }
            return switch projection.speech[turnID] {
            case .failed: .failed
            case .streaming, .ready: .playable
            case .retrying, nil: .waiting
            }
        case .failed: return .failed
        case .thinking, .retrying, nil: return .waiting
        }
    }

    func replyAutoPlayAction(
        for turnID: String,
        attemptedSpeechEventSeq: UInt64?,
        loadingID: String?,
        playingID: String?,
        lastFinishedID: String?
    ) -> ReplyAutoPlayAction {
        let projection = ConversationPresentation(events: self)
        guard case let .ready(reply) = projection.replies[turnID] else {
            return projection.replies[turnID]?.isFailed == true ? .failed : .wait
        }
        guard reply.audio != nil else { return .complete }
        let playbackID = PlaybackID.reply(turnID)
        guard let speech = projection.speech[turnID] else { return .wait }
        switch speech {
        case .failed:
            return .failed
        case .retrying:
            return .wait
        case .streaming, .ready:
            break
        }
        if loadingID == playbackID || playingID == playbackID {
            return .wait
        }
        if speech.isReady, lastFinishedID == playbackID {
            return .complete
        }
        guard let speechEventSeq = projection.speechEventSeq[turnID],
              attemptedSpeechEventSeq != speechEventSeq else { return .wait }
        return .startPlayback(speechEventSeq: speechEventSeq)
    }
}

enum ReplyReadiness: Equatable {
    case waiting
    case playable
    case failed
}

enum ReplyAutoPlayAction: Equatable {
    case wait
    case startPlayback(speechEventSeq: UInt64)
    case complete
    case failed
}

private enum TranscriptStatus {
    case transcribing
    case retrying
    case ready(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum ReplyFailureStage {
    case transcription
    case reply
}

private enum ReplyStatus {
    case thinking
    case retrying
    case ready(KiboEvent)
    case failed(String, ReplyFailureStage)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum SpeechStatus {
    case streaming(isRetry: Bool)
    case retrying
    case ready
    case failed(String)

    var permitsPlayback: Bool {
        switch self {
        case .streaming, .ready: true
        case .retrying, .failed: false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }
}

private struct ConversationPresentation {
    var turnIDs = Set<String>()
    var durations: [String: UInt64] = [:]
    var transcripts: [String: TranscriptStatus] = [:]
    var turnClips: [String: [String]] = [:]
    var replies: [String: ReplyStatus] = [:]
    var speech: [String: SpeechStatus] = [:]
    var speechEventSeq: [String: UInt64] = [:]
    /// First `image` commitment event per image ID (sha256/dimensions/caption).
    var imageEvents: [String: KiboEvent] = [:]
    /// Claim-time ordering key shared by clips and images.
    var mediaOrder: [String: (recordedAt: UInt64, seq: UInt64)] = [:]
    /// Turn events in seq order with their raw claim arrays.
    private var rawTurns: [(turnID: String, clips: [String], images: [String])] = []
    /// Every clip/image event in seq order (per event, not per unique ID).
    private var rawMedia: [ConversationMedia] = []

    init(events: [KiboEvent]) {
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            switch event.kind {
            case "clip":
                guard let clipID = event.id else { continue }
                durations[clipID] = event.ms
                if mediaOrder[clipID] == nil {
                    mediaOrder[clipID] = (event.recorded_at ?? 0, event.seq)
                }
                if transcripts[clipID] == nil { transcripts[clipID] = .transcribing }
                rawMedia.append(ConversationMedia(id: clipID, isImage: false))
            case "image":
                guard let imageID = event.id else { continue }
                if imageEvents[imageID] == nil { imageEvents[imageID] = event }
                if mediaOrder[imageID] == nil {
                    mediaOrder[imageID] = (event.recorded_at ?? 0, event.seq)
                }
                rawMedia.append(ConversationMedia(id: imageID, isImage: true))
            case "transcript_started":
                guard let clipID = event.clip,
                      transcripts[clipID]?.isReady != true,
                      transcripts[clipID]?.isFailed != true else { continue }
                transcripts[clipID] = event.attempt.map { $0 > 1 } == true
                    || isTranscriptRetrying(clipID) ? .retrying : .transcribing
            case "transcript_retry_scheduled":
                guard let clipID = event.clip,
                      transcripts[clipID]?.isReady != true,
                      transcripts[clipID]?.isFailed != true else { continue }
                transcripts[clipID] = .retrying
            case "transcript_retry_requested":
                guard let clipID = event.clip,
                      transcripts[clipID]?.isReady != true else { continue }
                transcripts[clipID] = .retrying
                reopenTranscriptDependentReplies(for: clipID, requireAllTranscriptsReady: false)
            case "transcript_error":
                guard let clipID = event.clip,
                      transcripts[clipID]?.isReady != true,
                      transcripts[clipID]?.isFailed != true else { continue }
                transcripts[clipID] = event.terminal == true
                    ? .failed(event.error ?? "Transcription failed")
                    : .retrying
            case "transcript":
                guard let clipID = event.clip,
                      transcripts[clipID]?.isReady != true,
                      transcripts[clipID]?.isFailed != true else { continue }
                transcripts[clipID] = .ready(event.text ?? "Transcribing…")
                reopenTranscriptDependentReplies(for: clipID, requireAllTranscriptsReady: true)
            case "turn":
                guard let turnID = event.id else { continue }
                turnIDs.insert(turnID)
                turnClips[turnID] = event.clips ?? []
                rawTurns.append((turnID, event.clips ?? [], event.images ?? []))
                if replies[turnID] == nil { replies[turnID] = .thinking }
            case "reply_started":
                guard let turnID = event.turn,
                      replies[turnID]?.isReady != true,
                      replies[turnID]?.isFailed != true else { continue }
                replies[turnID] = event.attempt.map { $0 > 1 } == true
                    || isReplyRetrying(turnID) ? .retrying : .thinking
            case "reply_retry_scheduled":
                guard let turnID = event.turn,
                      replies[turnID]?.isReady != true,
                      replies[turnID]?.isFailed != true else { continue }
                replies[turnID] = .retrying
            case "reply_retry_requested":
                guard let turnID = event.turn,
                      replies[turnID]?.isReady != true else { continue }
                replies[turnID] = .retrying
                speech[turnID] = nil
                speechEventSeq[turnID] = nil
            case "reply_error":
                guard let turnID = event.turn,
                      replies[turnID]?.isReady != true,
                      replies[turnID]?.isFailed != true else { continue }
                if event.terminal == true {
                    let stage: ReplyFailureStage = event.stage == "transcription" ? .transcription : .reply
                    replies[turnID] = .failed(event.error ?? "Reply failed", stage)
                } else {
                    replies[turnID] = .retrying
                }
            case "reply":
                guard let turnID = event.turn,
                      replies[turnID]?.isReady != true,
                      replies[turnID]?.isFailed != true else { continue }
                replies[turnID] = .ready(event)
            case "speech_started":
                guard let turnID = event.turn,
                      speech[turnID]?.isReady != true,
                      speech[turnID]?.isFailed != true else { continue }
                let isRetry = event.attempt.map { $0 > 1 } == true
                    || speech[turnID]?.isRetrying == true
                speech[turnID] = .streaming(isRetry: isRetry)
                speechEventSeq[turnID] = event.seq
            case "speech_retry_scheduled":
                guard let turnID = event.turn,
                      speech[turnID]?.isReady != true,
                      speech[turnID]?.isFailed != true else { continue }
                speech[turnID] = .retrying
            case "speech_retry_requested":
                guard let turnID = event.turn,
                      case let .ready(reply)? = replies[turnID],
                      reply.audio != nil,
                      speech[turnID] != nil else { continue }
                speech[turnID] = .retrying
            case "tts_error":
                guard let turnID = event.turn,
                      speech[turnID]?.isReady != true,
                      speech[turnID]?.isFailed != true else { continue }
                speech[turnID] = event.terminal == true
                    ? .failed(event.error ?? "Speech synthesis failed")
                    : .retrying
            case "speech_ready":
                guard let turnID = event.turn,
                      speech[turnID]?.isReady != true,
                      speech[turnID]?.isFailed != true else { continue }
                speech[turnID] = .ready
                speechEventSeq[turnID] = event.seq
            default:
                continue
            }
        }
    }

    /// The one ordering rule for conversation media: merge-sort clips and
    /// images by (recorded_at, seq), tie-breaking on the input's own ordinal
    /// rather than lexical ID — media whose referenced events are missing or
    /// malformed all share the (0, 0) key and must keep the server's order.
    private func orderedByClaim(_ media: [ConversationMedia]) -> [ConversationMedia] {
        media.enumerated().sorted { lhs, rhs in
            let left = mediaOrder[lhs.element.id] ?? (0, 0)
            let right = mediaOrder[rhs.element.id] ?? (0, 0)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// The conversation in presentation order: every consumer of "turns, each
    /// with its ordered claimed media, then the unclaimed tail" walks this,
    /// so the claim and ordering rules exist exactly once.
    func walk() -> ConversationWalk {
        var claimedClips = Set<String>()
        var claimedImages = Set<String>()
        var turns: [ConversationWalk.Turn] = []
        for raw in rawTurns {
            claimedClips.formUnion(raw.clips)
            claimedImages.formUnion(raw.images)
            let media = raw.clips.map { ConversationMedia(id: $0, isImage: false) }
                + raw.images.map { ConversationMedia(id: $0, isImage: true) }
            turns.append(ConversationWalk.Turn(
                turnID: raw.turnID,
                media: orderedByClaim(media)
            ))
        }
        let unclaimed = orderedByClaim(rawMedia.filter { item in
            item.isImage
                ? !claimedImages.contains(item.id)
                : !claimedClips.contains(item.id)
        })
        return ConversationWalk(turns: turns, unclaimed: unclaimed)
    }

    private func isTranscriptRetrying(_ clipID: String) -> Bool {
        if case .retrying = transcripts[clipID] { return true }
        return false
    }

    private func isReplyRetrying(_ turnID: String) -> Bool {
        if case .retrying = replies[turnID] { return true }
        return false
    }

    private mutating func reopenTranscriptDependentReplies(
        for clipID: String,
        requireAllTranscriptsReady: Bool
    ) {
        for (turnID, clipIDs) in turnClips where clipIDs.contains(clipID) {
            if requireAllTranscriptsReady,
               !clipIDs.allSatisfy({ transcripts[$0]?.isReady == true }) {
                continue
            }
            guard case .failed(_, .transcription) = replies[turnID] else { continue }
            replies[turnID] = .retrying
        }
    }
}
