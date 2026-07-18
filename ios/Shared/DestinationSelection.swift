import Foundation

extension KiboDestination {
    /// Nil-propagating factory: only builds a destination when both a
    /// project and a conversation are selected. Replaces three identical
    /// guard-and-construct bodies in AppStore/WatchStore's `requestDestination`.
    init?(serverURL: String, projectID: String?, conversationID: String?) {
        guard let projectID, let conversationID else { return nil }
        self.init(serverURL: serverURL, projectID: projectID, conversationID: conversationID)
    }
}

extension Sequence where Element == PendingClip {
    /// Pending clips destined for one server + conversation — the shared
    /// predicate behind `localAskableClipCount` and each store's in-flight
    /// voice markers.
    func matching(serverURL: String, destinationKey: String) -> [PendingClip] {
        filter { $0.serverURL == serverURL && $0.destinationKey == destinationKey }
    }
}
