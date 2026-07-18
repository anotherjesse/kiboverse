import SwiftUI

@main
struct KiboWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchTalkView()
                .tint(.kiboCoral)
        }
    }
}

@MainActor
final class WatchStore: ObservableObject {
    static let defaultServerURL = "https://jstew.stingray-nominal.ts.net/"

    private enum Key {
        static let serverURL = "watchServerURL"
        static let projectID = "watchSelectedProjectID"
        static let conversationID = "watchSelectedConversationID"
    }

    @Published var projects: [KiboProject] = []
    @Published var conversations: [KiboConversation] = []
    @Published var events: [KiboEvent] = []
    @Published private(set) var eventRevision: UInt64 = 0
    @Published var selectedProjectID: String?
    @Published var selectedConversationID: String?
    @Published var status = "Connecting…"
    @Published var errorMessage: String?
    @Published var isUploading = false
    @Published var isSubmitting = false
    @Published private(set) var isRetryingFailedWork = false
    @Published private(set) var isChangingServer = false
    @Published var pendingUploadCount = 0
    @Published private(set) var recoveryItemCount = 0
    @Published private(set) var pendingClips: [PendingClip] = []
    /// The conversation as the constellation renders it: server events plus
    /// watch-local spool state. Rebuilt when events or the spool change —
    /// never per frame; the view layer only does geometry.
    @Published private(set) var constellationMarkers: [ConstellationEvent] = []
    private var recoveryItemIDs: [String] = []

    /// Poll cadence contract (Tier 2 plan, Phase 0): no network while the
    /// scene is inactive; delta fetches only; fast cadence only while work
    /// is in flight, degrading if it never resolves.
    static let idlePollInterval: Duration = .seconds(10)
    static let fastPollInterval: Duration = .milliseconds(500)
    /// A fast window that runs this long without resolving degrades to the
    /// idle cadence — a wedged turn must not burn the radio indefinitely.
    static let fastPollingDegradeAfter: Duration = .seconds(120)
    /// Sleep granularity of the poll loop: cadence changes (an ask starting,
    /// a reply landing) take effect within one tick, no wakeup wiring.
    private static let pollTick: Duration = .milliseconds(500)

    private let defaults = UserDefaults.standard
    private let spool = PendingUploadSpool(directoryName: PendingUploadSpool.watchDirectoryName)
    private var api: KiboAPI
    private var pollTask: Task<Void, Never>?
    private var uploadTask: Task<Bool, Never>?
    private var hasStarted = false
    private var isSceneActive = true
    private var fastPollingSince: ContinuousClock.Instant?
    /// Events with seq ≤ this are already in `events`; kibod filters
    /// server-side, so each poll transfers only the delta.
    private(set) var eventsCursor: UInt64 = 0
    private var loadVersion = 0
    private var selectionVersion = 0
    private var eventRequestVersion = 0

    var serverURL: String {
        let raw = defaults.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        return KiboAPI.canonicalServerURL(raw) ?? Self.defaultServerURL
    }

    var selectedProject: KiboProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedConversation: KiboConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var isAskingKibo: Bool {
        isSubmitting || !events.pendingTurnIDs.isEmpty
    }

    /// Clips queued on this watch for the SELECTED conversation on the
    /// current server — the only local recordings the next "Ask" can claim.
    /// Recovery items and other conversations' clips are excluded so the
    /// Ask badge never advertises work an ask cannot submit.
    var localAskableClipCount: Int {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return 0 }
        let destinationKey = "\(projectID)/\(conversationID)"
        let serverURL = self.serverURL
        return pendingClips.lazy.filter {
            $0.serverURL == serverURL && $0.destinationKey == destinationKey
        }.count
    }

    var requestDestination: KiboDestination? {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return nil }
        return KiboDestination(
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID
        )
    }

    init(session: URLSession = .shared) {
        let raw = UserDefaults.standard.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        let canonical = KiboAPI.canonicalServerURL(raw) ?? Self.defaultServerURL
        api = try! KiboAPI(serverURL: canonical, session: session)
        selectedProjectID = defaults.string(forKey: Key.projectID)
        selectedConversationID = defaults.string(forKey: Key.conversationID)
        let inventory = spool.inventory()
        pendingUploadCount = inventory.protectedCount(for: canonical)
        recoveryItemCount = inventory.recoveryItems.count
        pendingClips = inventory.clips
        recoveryItemIDs = inventory.recoveryItems.map(\.id)
        rebuildConstellation()
    }

    deinit {
        pollTask?.cancel()
        uploadTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await load()
        _ = await retryPendingUploads()
        if isSceneActive { beginPolling() }
    }

    /// Phase 0 contract: zero network while the scene is inactive. The poll
    /// loop exists only while the app is frontmost and awake.
    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        if active {
            guard hasStarted else { return }
            beginPolling(refreshingImmediately: true)
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    var isPolling: Bool { pollTask != nil }

    func load() async {
        loadVersion += 1
        let version = loadVersion
        do {
            let loaded = try await api.projects()
            guard version == loadVersion else { return }
            projects = loaded
            let preferred = ProjectSelection.preferred(in: projects, savedID: selectedProjectID)
            await selectProject(preferred?.id)
            updatePendingUploadCount()
            if pendingUploadCount == 0 {
                status = "Live"
                errorMessage = nil
            }
        } catch {
            guard version == loadVersion else { return }
            report(error)
        }
    }

    func selectProject(_ id: String?) async {
        selectionVersion += 1
        let version = selectionVersion
        selectedProjectID = id
        selectedConversationID = nil
        conversations = []
        resetEventLog()
        persist(id, key: Key.projectID)
        guard let id else { return }
        do {
            let loaded = try await api.conversations(projectID: id)
            guard version == selectionVersion, id == selectedProjectID else { return }
            conversations = loaded
            let savedID = defaults.string(forKey: Key.conversationID)
            let preferred = conversations.first { $0.id == savedID } ?? conversations.first
            await selectConversation(preferred?.id)
        } catch {
            guard version == selectionVersion else { return }
            report(error)
        }
    }

    func selectConversation(_ id: String?) async {
        selectionVersion += 1
        selectedConversationID = id
        resetEventLog()
        persist(id, key: Key.conversationID)
        await refreshEvents()
    }

    @discardableResult
    func refreshEvents(quiet: Bool = false) async -> Bool {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return false }
        let version = selectionVersion
        eventRequestVersion += 1
        let requestVersion = eventRequestVersion
        do {
            let loaded = try await api.events(
                projectID: projectID,
                conversationID: conversationID,
                after: eventsCursor
            )
            guard version == selectionVersion,
                  requestVersion == eventRequestVersion,
                  projectID == selectedProjectID,
                  conversationID == selectedConversationID else { return false }
            // Only the newest-issued request can pass the guard above, so no
            // two responses ever append against the same cursor value.
            if !loaded.events.isEmpty {
                events.append(contentsOf: loaded.events)
            }
            eventsCursor = loaded.latest_seq
            if eventRevision < .max { eventRevision += 1 }
            updatePendingUploadCount()
            if pendingUploadCount == 0 && !isUploading {
                status = "Live"
                errorMessage = nil
            }
            return true
        } catch {
            guard !Task.isCancelled,
                  version == selectionVersion,
                  requestVersion == eventRequestVersion,
                  projectID == selectedProjectID,
                  conversationID == selectedConversationID else { return false }
            if !quiet || events.isEmpty { report(error) }
            return false
        }
    }

    func queueRecording(_ recording: WatchLocalRecording) {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else {
            errorMessage = "Choose a conversation first."
            return
        }
        do {
            _ = try spool.enqueue(
                recording: recording,
                serverURL: serverURL,
                projectID: projectID,
                conversationID: conversationID
            )
            updatePendingUploadCount()
            status = "Saved · sending…"
            Task {
                _ = await retryPendingUploads(destinationKey: "\(projectID)/\(conversationID)")
                await refreshEvents(quiet: true)
            }
        } catch {
            report(error)
        }
    }

    @discardableResult
    func submitTurn(
        serverURL: String,
        projectID: String,
        conversationID: String
    ) async -> String? {
        guard serverURL == self.serverURL,
              projectID == selectedProjectID,
              conversationID == selectedConversationID,
              !isSubmitting,
              !isChangingServer else { return nil }
        updatePendingUploadCount()
        guard recoveryItemCount == 0 else {
            status = "Open Server to resolve saved recordings"
            return nil
        }
        let destinationKey = "\(projectID)/\(conversationID)"
        guard await retryPendingUploads(destinationKey: destinationKey) else { return nil }
        guard !Task.isCancelled,
              serverURL == self.serverURL,
              projectID == selectedProjectID,
              conversationID == selectedConversationID else { return nil }
        updatePendingUploadCount()
        guard recoveryItemCount == 0 else {
            status = "Open Server to resolve saved recordings"
            return nil
        }
        guard !spool.all().contains(where: {
            $0.serverURL == serverURL && $0.destinationKey == destinationKey
        }) else { return nil }

        isSubmitting = true
        defer { isSubmitting = false }
        status = "Kibo is thinking…"
        let commandKey = "watchPendingTurnID.\(serverURL).\(destinationKey)"
        let turnID = defaults.string(forKey: commandKey) ?? UUID().uuidString.lowercased()
        defaults.set(turnID, forKey: commandKey)
        do {
            try await api.submitTurn(
                projectID: projectID,
                conversationID: conversationID,
                turnID: turnID
            )
            defaults.removeObject(forKey: commandKey)
            if serverURL == self.serverURL,
               projectID == selectedProjectID,
               conversationID == selectedConversationID {
                await refreshEvents()
            }
            return turnID
        } catch {
            if serverURL == self.serverURL,
               projectID == selectedProjectID,
               conversationID == selectedConversationID {
                report(error)
            }
            return nil
        }
    }

    func speechStream(
        destination: KiboDestination,
        turnID: String,
        fromSample: Int,
        generation: String? = nil
    ) async throws -> SpeechResponseStream {
        guard destination == requestDestination else {
            throw APIError.requestDestinationChanged
        }
        let response = try await api.speechStream(
            destination: destination,
            turnID: turnID,
            fromSample: fromSample,
            generation: generation
        )
        guard destination == requestDestination else {
            throw APIError.requestDestinationChanged
        }
        return response
    }

    func retryFailedWork(
        _ target: RetryTarget,
        serverURL: String,
        projectID: String,
        conversationID: String
    ) async -> RetryWorkOutcome {
        guard serverURL == self.serverURL,
              projectID == selectedProjectID,
              conversationID == selectedConversationID,
              !isRetryingFailedWork,
              !isChangingServer else { return .notAccepted }
        isRetryingFailedWork = true
        defer { isRetryingFailedWork = false }
        do {
            switch target {
            case let .clip(clipID):
                try await api.retryClip(
                    projectID: projectID, conversationID: conversationID, clipID: clipID
                )
            case let .turn(turnID):
                try await api.retryTurn(
                    projectID: projectID, conversationID: conversationID, turnID: turnID
                )
            }
            let requiredEventsRevision = eventRevision < .max
                ? eventRevision + 1
                : eventRevision
            let stillSelected = serverURL == self.serverURL
                && projectID == selectedProjectID
                && conversationID == selectedConversationID
            if stillSelected {
                status = "Retrying…"
                errorMessage = nil
            }
            if stillSelected { await refreshEvents() }
            return .accepted(requiredEventsRevision: requiredEventsRevision)
        } catch {
            if serverURL == self.serverURL,
               projectID == selectedProjectID,
               conversationID == selectedConversationID {
                report(error)
            }
            return .notAccepted
        }
    }

    func saveServer(_ value: String) async -> Bool {
        guard !isUploading, !isSubmitting, !isRetryingFailedWork, !isChangingServer else {
            errorMessage = "Wait for the current request to finish."
            return false
        }
        refreshRecordingInventory()
        guard pendingUploadCount == 0 else {
            errorMessage = "Let saved recordings finish sending before changing servers."
            return false
        }
        guard let canonicalURL = KiboAPI.canonicalServerURL(value) else {
            report(APIError.invalidServerURL)
            return false
        }
        if canonicalURL == serverURL { return true }
        isChangingServer = true
        defer { isChangingServer = false }
        do {
            // Invalidate the selected destination before the shared API actor
            // changes its base URL. Commands are also barred by
            // isChangingServer, so no request can straddle this boundary.
            loadVersion += 1
            selectionVersion += 1
            selectedProjectID = nil
            selectedConversationID = nil
            projects = []
            conversations = []
            resetEventLog()
            try await api.setServerURL(canonicalURL)
            defaults.set(canonicalURL, forKey: Key.serverURL)
            await load()
            return errorMessage == nil
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    private func retryPendingUploads(destinationKey: String? = nil) async -> Bool {
        if let uploadTask { return await uploadTask.value }
        let candidates = spool.all().filter {
            $0.serverURL == serverURL
                && (destinationKey == nil || $0.destinationKey == destinationKey)
        }
        guard !candidates.isEmpty else {
            updatePendingUploadCount()
            return true
        }
        let ids = Set(candidates.map(\.id))
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performPendingUploads(ids: ids)
        }
        uploadTask = task
        let result = await task.value
        uploadTask = nil
        return result
    }

    private func performPendingUploads(ids: Set<String>) async -> Bool {
        let pending = spool.all().filter { ids.contains($0.id) && $0.serverURL == serverURL }
        guard !pending.isEmpty else { return true }
        isUploading = true
        status = "Sending recordings…"
        defer {
            isUploading = false
            updatePendingUploadCount()
        }
        var allSent = true
        for clip in pending {
            do {
                try await api.uploadClip(
                    fileURL: spool.wavURL(for: clip),
                    projectID: clip.projectID,
                    conversationID: clip.conversationID,
                    clipID: clip.id,
                    durationMs: clip.durationMs,
                    peakPct: clip.peakPct,
                    recordedAt: clip.recordedAt,
                    expectedSHA256: clip.sha256
                )
                spool.remove(clip)
            } catch APIError.localRecordingChanged {
                allSent = false
                do {
                    try spool.quarantine(
                        clip,
                        reason: .audioChecksumMismatch,
                        detail: "The WAV no longer matches the checksum saved when it was queued."
                    )
                    status = "Recording recovery needed"
                    errorMessage = "A saved recording changed. Open Server to review it."
                } catch {
                    status = "Saved on this Watch"
                    errorMessage = "The recording changed and could not be quarantined. \(error.localizedDescription)"
                }
            } catch {
                allSent = false
                status = "Saved on this Watch"
                errorMessage = "Recording saved; sending will retry. \(error.localizedDescription)"
            }
        }
        if allSent { status = "Thought saved" }
        return allSent
    }

    func discardPendingUploads() {
        guard !isUploading else {
            errorMessage = "Wait for the current upload to finish before discarding recordings."
            return
        }
        let inventory = spool.inventory()
        for clip in inventory.clips where clip.serverURL == serverURL { spool.remove(clip) }
        do {
            for recovery in inventory.recoveryItems { try spool.remove(recovery) }
        } catch {
            updatePendingUploadCount()
            status = "Recording recovery needed"
            errorMessage = "Some saved recordings could not be discarded. \(error.localizedDescription)"
            return
        }
        updatePendingUploadCount()
        errorMessage = nil
        status = "Saved recordings discarded"
    }

    private func beginPolling(refreshingImmediately: Bool = false) {
        pollTask?.cancel()
        fastPollingSince = nil
        pollTask = Task { [weak self] in
            var lastFetch: ContinuousClock.Instant? = refreshingImmediately ? nil : .now
            while !Task.isCancelled {
                if lastFetch != nil {
                    try? await Task.sleep(for: Self.pollTick)
                }
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let due = lastFetch.map {
                    $0.duration(to: now) >= self.nextPollInterval(now: now)
                } ?? true
                guard due else { continue }
                if self.projects.isEmpty {
                    await self.load()
                } else {
                    await self.refreshEvents(quiet: true)
                }
                lastFetch = ContinuousClock.now
            }
        }
    }

    /// Decides the current fetch cadence: fast only while kibod is doing
    /// work this watch is waiting on, degrading after
    /// `fastPollingDegradeAfter` so an unresolved window cannot poll fast
    /// forever. While `projects` is empty only `load()` retries, at the
    /// idle cadence.
    func nextPollInterval(now: ContinuousClock.Instant = .now) -> Duration {
        let needsFast = !projects.isEmpty && (isSubmitting || events.needsFastPolling)
        guard needsFast else {
            fastPollingSince = nil
            return Self.idlePollInterval
        }
        let since = fastPollingSince ?? now
        fastPollingSince = since
        return since.duration(to: now) > Self.fastPollingDegradeAfter
            ? Self.idlePollInterval
            : Self.fastPollInterval
    }

    private func resetEventLog() {
        events = []
        eventsCursor = 0
        rebuildConstellation()
    }

    private func updatePendingUploadCount() {
        let inventory = spool.inventory()
        pendingUploadCount = inventory.protectedCount(for: serverURL)
        recoveryItemCount = inventory.recoveryItems.count
        pendingClips = inventory.clips
        recoveryItemIDs = inventory.recoveryItems.map(\.id)
        rebuildConstellation()
        if recoveryItemCount > 0 && !isUploading && errorMessage == nil {
            status = "Recording recovery needed"
        }
    }

    private func rebuildConstellation() {
        var markers = events.constellation()
        var known = Set(markers.map(\.id))
        // Spooled clips for the selected destination render as in-flight
        // voice markers. The spool ID becomes the server clip ID on upload,
        // so each marker keeps its place when the server event lands.
        if let projectID = selectedProjectID,
           let conversationID = selectedConversationID {
            let destinationKey = "\(projectID)/\(conversationID)"
            let serverURL = self.serverURL
            for clip in pendingClips
            where clip.serverURL == serverURL && clip.destinationKey == destinationKey {
                guard known.insert(clip.id).inserted else { continue }
                markers.append(ConstellationEvent(
                    id: clip.id, kind: .voice, phase: .working, contextIDs: []
                ))
            }
        }
        // Recovery items block every ask, so they show regardless of the
        // selected conversation. Prefixed: a quarantined clip must not
        // collide with a server marker for the same recording.
        for recoveryID in recoveryItemIDs {
            let markerID = "recovery-\(recoveryID)"
            guard known.insert(markerID).inserted else { continue }
            markers.append(ConstellationEvent(
                id: markerID, kind: .voice, phase: .failed, contextIDs: []
            ))
        }
        if constellationMarkers != markers { constellationMarkers = markers }
    }

    func refreshRecordingInventory() {
        updatePendingUploadCount()
    }

    private func persist(_ value: String?, key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private func report(_ error: Error) {
        status = "Offline"
        errorMessage = error.localizedDescription
    }
}
