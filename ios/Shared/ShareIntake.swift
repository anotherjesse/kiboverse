import Foundation

/// The share extension UI's whole state space. A value type in Shared so the
/// reducers below — and therefore every phase the extension can display —
/// are unit-tested from the main app's test bundle (the KiboShare target has
/// none).
enum ShareIntakePhase: Equatable {
    /// Terminal: nothing can be saved (no app group, no cache, no images).
    case unavailable(String)
    case ready
    case saving(completed: Int, total: Int)
    /// `count < total` means some images failed to load or enqueue — the
    /// UI must say so; a partial save is never presented as a full one.
    case saved(count: Int, total: Int)
    case failed(String)
}

/// Pure policy for the share-extension intake, kept in Shared so the main
/// app's unit tests cover it (the KiboShare target itself has no test bundle).
enum ShareIntake {
    /// Share-sheet text becomes the caption of the FIRST spooled image only.
    /// A caption is user text and TurnContent renders every caption exactly
    /// once (PLAN §3.4 caption uniformity), so stamping the same text onto N
    /// images would repeat it N times in the prompt, history, and knowledge.
    /// `spooledIndex` counts successful enqueues, not providers — if the
    /// first provider fails to load, the text still lands on the first image
    /// that actually spools.
    static func caption(forSpooledImageAt spooledIndex: Int, sharedText: String?) -> String? {
        guard spooledIndex == 0 else { return nil }
        return PendingAttachmentSpool.boundedCaption(sharedText)
    }

    /// The phase the extension opens in, decided from the three seams it
    /// depends on — checked in dependency order: no spool (no app group on
    /// this install) beats no cached destination beats no shareable images.
    static func initialPhase(
        spoolAvailable: Bool,
        hasDefaultDestination: Bool,
        imageCount: Int
    ) -> ShareIntakePhase {
        guard spoolAvailable else {
            return .unavailable("Sharing into Kibo is not available on this install.")
        }
        guard hasDefaultDestination else {
            return .unavailable("Open Kibo first to connect, then share photos here.")
        }
        guard imageCount > 0 else {
            return .unavailable("Kibo can only save shared images.")
        }
        return .ready
    }

    /// The terminal phase after the last provider was attempted: zero
    /// successes is a failure; anything else reports the honest count so a
    /// partial save is never presented as a full one.
    static func completionPhase(spooled: Int, total: Int) -> ShareIntakePhase {
        guard spooled > 0 else {
            return .failed("Those images could not be saved. Try sharing them again.")
        }
        return .saved(count: spooled, total: total)
    }
}
