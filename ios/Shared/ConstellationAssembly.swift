import Foundation

/// One local marker a store contributes to the constellation: a spooled
/// recording/attachment still uploading, or a quarantined recovery item.
/// Typed so a quarantined image renders as an amber diamond, never a voice
/// star — string-typed local arrays could not make that distinction.
struct LocalMarker: Hashable {
    /// Final identity, including any "recovery-" prefix, chosen by the store.
    let id: String
    let kind: ConstellationEvent.Kind
    let phase: ConstellationEvent.Phase
}

/// Pure dedupe + order policy shared by every store's constellation
/// projection: server markers first (`events.constellation()`), then local
/// markers appended in the order given, skipping any ID the server already
/// owns. A spooled clip keeps its spool ID as the server clip ID, so when
/// the server event lands the marker keeps its place instead of duplicating.
enum ConstellationAssembly {
    static func markers(events: [KiboEvent], local: [LocalMarker]) -> [ConstellationEvent] {
        var markers = events.constellation()
        var known = Set(markers.map(\.id))
        for marker in local {
            guard known.insert(marker.id).inserted else { continue }
            markers.append(ConstellationEvent(
                id: marker.id, kind: marker.kind, phase: marker.phase, contextIDs: []
            ))
        }
        return markers
    }
}
