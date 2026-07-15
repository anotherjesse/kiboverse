import Foundation

struct KiboProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }
}

enum ProjectSelection {
    static func preferred(in projects: [KiboProject], savedID: String?) -> KiboProject? {
        projects.first { $0.id == savedID } ?? projects.first
    }
}

struct KiboConversation: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let name: String
    let nameSource: String?
    let createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectId = "project_id"
        case nameSource = "name_source"
        case createdAt = "created_at"
    }
}

struct KiboEvent: Codable, Identifiable, Hashable {
    let seq: UInt64
    let kind: String
    let idValue: String?
    let clip: String?
    let turn: String?
    let text: String?
    let error: String?
    let audio: String?
    let clips: [String]?
    let durationMs: UInt64?
    let peakPct: UInt64?
    let createdAt: UInt64?

    var id: UInt64 { seq }

    enum CodingKeys: String, CodingKey {
        case seq, kind, clip, turn, text, error, audio, clips
        case idValue = "id"
        case durationMs = "ms"
        case peakPct = "peak"
        case createdAt = "at"
    }
}

struct ProjectsEnvelope: Codable { let projects: [KiboProject] }
struct ConversationsEnvelope: Codable { let conversations: [KiboConversation] }
struct EventsEnvelope: Codable {
    let events: [KiboEvent]
    let latestSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case events
        case latestSeq = "latest_seq"
    }
}

struct TimelineItem: Identifiable, Hashable {
    enum Role: Hashable { case person, kibo, status, error }
    let id: String
    let role: Role
    let title: String
    let body: String
    let turnID: String?
    let clipIDs: [String]
    let canPlay: Bool
}

extension Array where Element == KiboEvent {
    var pendingTurnIDs: Set<String> {
        let turns = Set(compactMap { $0.kind == "turn" ? $0.idValue : nil })
        let finished = Set(compactMap { event in
            (event.kind == "reply" || event.kind == "reply_error") ? event.turn : nil
        })
        return turns.subtracting(finished)
    }

    func timeline() -> [TimelineItem] {
        var transcripts: [String: String] = [:]
        var transcriptErrors: [String: String] = [:]
        var replies: [String: KiboEvent] = [:]
        var replyErrors: [String: String] = [:]
        var speechState: [String: SpeechStatus] = [:]
        for event in sorted(by: { $0.seq < $1.seq }) {
            if event.kind == "transcript", let clip = event.clip {
                transcripts[clip] = event.text ?? "Transcribing…"
            } else if event.kind == "transcript_error", let clip = event.clip {
                transcriptErrors[clip] = event.error ?? "Transcription failed"
            } else if event.kind == "reply", let turn = event.turn {
                replies[turn] = event
            } else if event.kind == "reply_error", let turn = event.turn {
                replyErrors[turn] = event.error ?? "Reply failed"
            } else if event.kind == "speech_ready", let turn = event.turn {
                speechState[turn] = .ready
            } else if event.kind == "tts_error", let turn = event.turn {
                speechState[turn] = .failed(event.error ?? "Speech synthesis failed")
            }
        }
        var claimed = Set<String>()
        var result: [TimelineItem] = []

        for event in self where event.kind == "turn" {
            guard let turnID = event.idValue else { continue }
            let clipIDs = event.clips ?? []
            claimed.formUnion(clipIDs)
            let thoughts = clipIDs.map { id in transcripts[id] ?? transcriptErrors[id] ?? "Transcribing…" }
            result.append(TimelineItem(
                id: "person-\(turnID)", role: .person, title: "You",
                body: thoughts.joined(separator: "\n"), turnID: nil,
                clipIDs: clipIDs, canPlay: false
            ))
            if let reply = replies[turnID] {
                let speechError: String? = if case let .failed(message) = speechState[turnID] { message } else { nil }
                result.append(TimelineItem(
                    id: "kibo-\(turnID)", role: .kibo, title: "Kibo",
                    body: [reply.text ?? "Reply ready", speechError.map { "Speech unavailable: \($0)" }]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                    turnID: turnID, clipIDs: [],
                    canPlay: speechError == nil && (speechState[turnID]?.isReady == true || reply.audio != nil)
                ))
            } else if let error = replyErrors[turnID] {
                result.append(TimelineItem(
                    id: "error-\(turnID)", role: .error, title: "Reply failed",
                    body: error, turnID: nil, clipIDs: [], canPlay: false
                ))
            } else {
                result.append(TimelineItem(
                    id: "status-\(turnID)", role: .status, title: "Kibo",
                    body: "Thinking…", turnID: nil, clipIDs: [], canPlay: false
                ))
            }
        }

        for event in self where event.kind == "clip" {
            guard let clipID = event.idValue, !claimed.contains(clipID) else { continue }
            result.append(TimelineItem(
                id: "clip-\(clipID)", role: .person, title: "You · not asked yet",
                body: transcripts[clipID] ?? transcriptErrors[clipID] ?? "Transcribing…",
                turnID: nil, clipIDs: [clipID], canPlay: false
            ))
        }
        return result
    }
}

private enum SpeechStatus {
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
