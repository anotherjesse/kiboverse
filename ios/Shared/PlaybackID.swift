import Foundation

/// The audio coordinators' `loadingID`/`playingID`/`lastFinishedID` are
/// plain strings tagged by source so a clip and a reply never collide when
/// matched against an in-flight playback id. One place mints them.
enum PlaybackID {
    static func reply(_ turnID: String) -> String { "reply-\(turnID)" }
    static func clip(_ clipID: String) -> String { "clip-\(clipID)" }
    static func isReply(_ id: String?) -> Bool { id?.hasPrefix("reply-") == true }
}
