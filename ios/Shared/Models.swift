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
}

extension Array where Element == KiboEvent {
    var pendingTurnIDs: Set<String> {
        let turns = Set(compactMap { $0.kind == "turn" ? $0.id : nil })
        let finished = Set(compactMap { event in
            (event.kind == "reply" || event.kind == "reply_error") ? event.turn : nil
        })
        return turns.subtracting(finished)
    }

    func timeline() -> [TimelineItem] {
        var transcripts: [String: String] = [:]
        var transcriptErrors: [String: String] = [:]
        var durations: [String: UInt64] = [:]
        var replies: [String: KiboEvent] = [:]
        var replyErrors: [String: String] = [:]
        var speechState: [String: SpeechStatus] = [:]
        for event in sorted(by: { $0.seq < $1.seq }) {
            if event.kind == "clip", let clip = event.id {
                durations[clip] = event.ms
            } else if event.kind == "transcript", let clip = event.clip {
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

        func personCard(clipID: String, title: String) -> TimelineItem {
            TimelineItem(
                id: "clip-\(clipID)", role: .person, title: title,
                body: transcripts[clipID] ?? transcriptErrors[clipID] ?? "Transcribing…",
                turnID: nil, clipID: clipID, durationMs: durations[clipID], canPlay: true
            )
        }

        for event in self where event.kind == "turn" {
            guard let turnID = event.id else { continue }
            let clipIDs = event.clips ?? []
            claimed.formUnion(clipIDs)
            // One card per recording, not one clump per turn.
            for clipID in clipIDs {
                result.append(personCard(clipID: clipID, title: "You"))
            }
            if let reply = replies[turnID] {
                let speechError: String? = if case let .failed(message) = speechState[turnID] { message } else { nil }
                result.append(TimelineItem(
                    id: "kibo-\(turnID)", role: .kibo, title: "Kibo",
                    body: [reply.text ?? "Reply ready", speechError.map { "Speech unavailable: \($0)" }]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                    turnID: turnID, clipID: nil, durationMs: nil,
                    canPlay: speechError == nil && (speechState[turnID]?.isReady == true || reply.audio != nil)
                ))
            } else if let error = replyErrors[turnID] {
                result.append(TimelineItem(
                    id: "error-\(turnID)", role: .error, title: "Reply failed",
                    body: error, turnID: nil, clipID: nil, durationMs: nil, canPlay: false
                ))
            } else {
                result.append(TimelineItem(
                    id: "status-\(turnID)", role: .status, title: "Kibo",
                    body: "Thinking…", turnID: nil, clipID: nil, durationMs: nil, canPlay: false
                ))
            }
        }

        for event in self where event.kind == "clip" {
            guard let clipID = event.id, !claimed.contains(clipID) else { continue }
            result.append(personCard(clipID: clipID, title: "You · not asked yet"))
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
