import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    private struct UploadRunResult {
        let attemptedIDs: Set<String>
    }

    /// Snapshot of the mutable API endpoint and UI selection that authorized
    /// an asynchronous command. The version fields make an away-and-back
    /// selection change different from the original destination.
    private struct LifecycleClaim {
        let serverVersion: Int
        let projectSelectionVersion: Int
        let eventSelectionVersion: Int
        let serverURL: String
        let projectID: String?
        let conversationID: String?
    }

    static let defaultServerURL = "https://wideboi.stingray-nominal.ts.net/"
    private enum Key {
        static let serverURL = "serverURL"
        static let projectID = "selectedProjectID"
        static let conversationID = "selectedConversationID"
    }

    @Published var projects: [KiboProject] = []
    @Published var conversations: [KiboConversation] = []
    @Published var events: [KiboEvent] = []
    @Published var selectedProjectID: String?
    @Published var selectedConversationID: String?
    @Published var serverURL: String
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var isSubmitting = false
    @Published private(set) var isRetryingFailedWork = false
    @Published private(set) var isChangingServer = false
    @Published var pendingUploadCount = 0
    @Published private(set) var recoveryItemCount = 0
    @Published private(set) var pendingClips: [PendingClip] = []
    /// True once the launch selection restore (projects → conversations →
    /// events) has settled — success or failure. RootView holds intent-driven
    /// navigation until then.
    @Published private(set) var hasRestoredSelection = false
    @Published var status = "Connecting…"
    @Published var errorMessage: String?

    private var api: KiboAPI
    private var pollTask: Task<Void, Never>?
    private var uploadTask: (id: UUID, task: Task<UploadRunResult, Never>)?
    private var recordingTasks: [UUID: Task<Void, Never>] = [:]
    private let spool = PendingUploadSpool(directoryName: PendingUploadSpool.phoneDirectoryName)
    private var isCreating = false
    private var serverVersion = 0
    private var projectSelectionVersion = 0
    private var eventSelectionVersion = 0
    private var eventRequestVersion = 0

    init(session: URLSession = .shared) {
        let rawURL = UserDefaults.standard.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        let savedURL = KiboAPI.canonicalServerURL(rawURL) ?? Self.defaultServerURL
        serverURL = savedURL
        api = (try? KiboAPI(serverURL: savedURL, session: session))
            ?? (try! KiboAPI(serverURL: Self.defaultServerURL, session: session))
        selectedProjectID = UserDefaults.standard.string(forKey: Key.projectID)
        selectedConversationID = UserDefaults.standard.string(forKey: Key.conversationID)
        let inventory = spool.inventory()
        pendingUploadCount = inventory.protectedCount(for: savedURL)
        recoveryItemCount = inventory.recoveryItems.count
        pendingClips = inventory.clips
    }

    deinit {
        pollTask?.cancel()
        uploadTask?.task.cancel()
        for task in recordingTasks.values { task.cancel() }
    }

    var selectedProject: KiboProject? { projects.first { $0.id == selectedProjectID } }
    var selectedConversation: KiboConversation? { conversations.first { $0.id == selectedConversationID } }
    var timeline: [TimelineItem] { events.timeline() }
    var isAskingKibo: Bool { isSubmitting || !events.pendingTurnIDs.isEmpty }
    /// Recordings the next "Ask Kibo" would claim: clips already on the
    /// server that no turn has claimed, plus recordings queued on this device
    /// for the SELECTED conversation. Clips spooled for other conversations
    /// and recovery items never count — an ask cannot submit those, and
    /// advertising them would re-enable the 409 path.
    var askableClipCount: Int { events.unclaimedClipCount + localAskableClipCount }
    /// Locally spooled clips destined for the selected conversation on the
    /// current server.
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

    func start() async {
        await reloadProjects()
        hasRestoredSelection = true
        _ = await retryPendingUploads()
        beginPolling()
    }

    func reloadProjects(quiet: Bool = false) async {
        let version = serverVersion
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await api.projects()
            guard version == serverVersion else { return }
            projects = loaded
            updatePendingUploadCount()
            if pendingUploadCount == 0 {
                status = "Live"
                errorMessage = nil
            }
            let preferred = ProjectSelection.preferred(in: projects, savedID: selectedProjectID)
            await selectProject(preferred?.id)
        } catch {
            guard version == serverVersion else { return }
            report(error, quiet: quiet)
        }
    }

    func selectProject(_ id: String?) async {
        guard selectedProjectID != id || conversations.isEmpty else { return }
        projectSelectionVersion += 1
        eventSelectionVersion += 1
        let version = projectSelectionVersion
        // Re-selecting the already-selected project (startup restore,
        // reconnect after being offline) must not tear down the restored
        // conversation: a transient nil destination would abort an
        // in-progress hold into recovery.
        let retainedConversationID = selectedProjectID == id ? selectedConversationID : nil
        selectedProjectID = id
        selectedConversationID = retainedConversationID
        conversations = []
        events = []
        persist(id, key: Key.projectID)
        guard let id else { conversations = []; return }
        do {
            let loaded = try await api.conversations(projectID: id)
            guard version == projectSelectionVersion, selectedProjectID == id else { return }
            conversations = loaded
            let stored = UserDefaults.standard.string(forKey: Key.conversationID)
            let preferred = conversations.first { $0.id == stored } ?? conversations.first
            await selectConversation(preferred?.id)
        } catch {
            guard version == projectSelectionVersion, selectedProjectID == id else { return }
            report(error)
        }
    }

    func selectConversation(_ id: String?) async {
        eventSelectionVersion += 1
        selectedConversationID = id
        events = []
        persist(id, key: Key.conversationID)
        await refreshEvents()
    }

    func refreshEvents() async {
        guard let project = selectedProjectID, let conversation = selectedConversationID else {
            events = []
            return
        }
        let version = eventSelectionVersion
        eventRequestVersion += 1
        let requestVersion = eventRequestVersion
        do {
            let loaded = try await api.events(projectID: project, conversationID: conversation).events
            guard version == eventSelectionVersion,
                  requestVersion == eventRequestVersion,
                  project == selectedProjectID, conversation == selectedConversationID else { return }
            events = loaded
            updatePendingUploadCount()
            if pendingUploadCount == 0 && !isUploading { status = "Live"; errorMessage = nil }
        } catch {
            guard !Task.isCancelled,
                  version == eventSelectionVersion,
                  requestVersion == eventRequestVersion,
                  project == selectedProjectID, conversation == selectedConversationID else { return }
            report(error, quiet: !events.isEmpty)
        }
    }

    func createProject(name: String) async {
        guard !isCreating, !isChangingServer else { return }
        let claim = lifecycleClaim()
        isCreating = true
        defer { isCreating = false }
        do {
            let project = try await api.createProject(name: name)
            guard !Task.isCancelled, accepts(claim) else { return }
            let loaded = try await api.projects()
            guard !Task.isCancelled, accepts(claim) else { return }
            projects = loaded
            updatePendingUploadCount()
            if pendingUploadCount == 0 {
                status = "Live"
                errorMessage = nil
            }
            await selectProject(project.id)
        } catch {
            guard !Task.isCancelled, accepts(claim) else { return }
            report(error)
        }
    }

    func createConversation(name: String? = nil) async {
        guard let projectID = selectedProjectID,
              !isCreating,
              !isChangingServer else { return }
        let claim = lifecycleClaim()
        isCreating = true
        defer { isCreating = false }
        do {
            let conversation = try await api.createConversation(projectID: projectID, name: name)
            guard !Task.isCancelled, accepts(claim) else { return }
            let loaded = try await api.conversations(projectID: projectID)
            guard !Task.isCancelled, accepts(claim) else { return }
            conversations = loaded
            await selectConversation(conversation.id)
        } catch {
            guard !Task.isCancelled, accepts(claim) else { return }
            report(error)
        }
    }

    func queueRecording(_ recording: LocalRecording) {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else {
            errorMessage = "Choose a project and conversation first."
            return
        }
        do {
            _ = try spool.enqueue(
                recording: recording, serverURL: serverURL,
                projectID: projectID, conversationID: conversationID
            )
            updatePendingUploadCount()
            status = "Saved locally · sending…"
            let taskID = UUID()
            recordingTasks[taskID] = Task { [weak self] in
                guard let self else { return }
                _ = await retryPendingUploads(destinationKey: "\(projectID)/\(conversationID)")
                await refreshEvents()
                recordingTasks[taskID] = nil
            }
        } catch {
            report(error)
        }
    }

    /// Test/support seam: queued recording work is explicit rather than an
    /// untracked task that can leak requests into a later lifecycle.
    func waitForRecordingTasks() async {
        while let task = recordingTasks.values.first { await task.value }
    }

    @discardableResult
    func retryPendingUploads(destinationKey: String? = nil) async -> Bool {
        await retryPendingUploads(destinationKey: destinationKey, excluding: [])
    }

    private func retryPendingUploads(
        destinationKey: String?,
        excluding attemptedIDs: Set<String>
    ) async -> Bool {
        if let running = uploadTask {
            let result = await running.task.value
            if uploadTask?.id == running.id { uploadTask = nil }
            return await retryPendingUploads(
                destinationKey: destinationKey,
                excluding: attemptedIDs.union(result.attemptedIDs)
            )
        }

        let matching = spool.all().filter {
            $0.serverURL == serverURL && (destinationKey == nil || $0.destinationKey == destinationKey)
        }
        let candidates = matching.filter { !attemptedIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            updatePendingUploadCount()
            return matching.isEmpty
        }
        let candidateIDs = Set(candidates.map(\.id))
        let runID = UUID()
        let task = Task { [weak self] in
            guard let self else { return UploadRunResult(attemptedIDs: []) }
            return await self.performPendingUploads(candidateIDs: candidateIDs)
        }
        uploadTask = (runID, task)
        let result = await task.value
        if uploadTask?.id == runID { uploadTask = nil }
        return await retryPendingUploads(
            destinationKey: destinationKey,
            excluding: attemptedIDs.union(result.attemptedIDs)
        )
    }

    private func performPendingUploads(candidateIDs: Set<String>) async -> UploadRunResult {
        let pending = spool.all().filter {
            $0.serverURL == serverURL && candidateIDs.contains($0.id)
        }
        guard !pending.isEmpty else {
            updatePendingUploadCount()
            isUploading = false
            return UploadRunResult(attemptedIDs: candidateIDs)
        }
        isUploading = true
        status = "Sending saved recordings…"
        defer {
            isUploading = false
            updatePendingUploadCount()
        }
        var allSent = true
        for clip in pending {
            do {
                try await api.uploadClip(
                    fileURL: spool.wavURL(for: clip),
                    projectID: clip.projectID, conversationID: clip.conversationID,
                    clipID: clip.id, durationMs: clip.durationMs,
                    peakPct: clip.peakPct, recordedAt: clip.recordedAt,
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
                    errorMessage = "A saved recording changed before upload. Review it in Settings."
                } catch {
                    status = "Saved on this iPhone"
                    errorMessage = "The recording changed and could not be quarantined. \(error.localizedDescription)"
                }
            } catch {
                allSent = false
                status = "Saved on this iPhone"
                errorMessage = "Recording saved locally; upload will retry. \(error.localizedDescription)"
            }
        }
        if allSent && !pending.isEmpty { status = "Thought saved" }
        return UploadRunResult(attemptedIDs: Set(pending.map(\.id)))
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

    @discardableResult
    func submitTurn() async -> String? {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else { return nil }
        guard !isUploading, !isSubmitting, !isChangingServer else { return nil }
        let claim = lifecycleClaim()
        updatePendingUploadCount()
        guard recoveryItemCount == 0 else {
            status = "Resolve recording recovery in Settings before asking Kibo"
            return nil
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let destination = "\(projectID)/\(conversationID)"
        guard await retryPendingUploads(destinationKey: destination) else { return nil }
        guard !Task.isCancelled, accepts(claim) else { return nil }
        updatePendingUploadCount()
        guard recoveryItemCount == 0 else {
            status = "Resolve recording recovery in Settings before asking Kibo"
            return nil
        }
        guard !spool.all().contains(where: {
            $0.serverURL == claim.serverURL && $0.destinationKey == destination
        }) else { return nil }
        status = "Kibo is thinking…"
        let commandKey = "pendingTurnID.\(claim.serverURL).\(destination)"
        let turnID = UserDefaults.standard.string(forKey: commandKey)
            ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(turnID, forKey: commandKey)
        do {
            guard !Task.isCancelled, accepts(claim) else { return nil }
            try await api.submitTurn(
                projectID: projectID, conversationID: conversationID,
                turnID: turnID
            )
            UserDefaults.standard.removeObject(forKey: commandKey)
            guard !Task.isCancelled, accepts(claim) else { return nil }
            await refreshEvents()
            guard !Task.isCancelled, accepts(claim) else { return nil }
            restartPollingIfStarted()
            return turnID
        } catch {
            guard !Task.isCancelled, accepts(claim) else { return nil }
            report(error)
            return nil
        }
    }

    func updateServerURL(_ value: String) async -> Bool {
        guard !isUploading, !isSubmitting, !isCreating,
              !isRetryingFailedWork, !isChangingServer else {
            errorMessage = "Wait for the current upload, create, or Kibo request to finish before changing servers."
            return false
        }
        refreshRecordingInventory()
        guard pendingUploadCount == 0 else {
            errorMessage = "Retry or discard saved recordings before changing servers."
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
            // No command may straddle the mutable API actor's base-URL
            // change. Invalidate the selected destination before switching.
            serverVersion += 1
            projectSelectionVersion += 1
            eventSelectionVersion += 1
            selectedProjectID = nil
            selectedConversationID = nil
            projects = []
            conversations = []
            events = []
            try await api.setServerURL(canonicalURL)
            serverURL = canonicalURL
            UserDefaults.standard.set(serverURL, forKey: Key.serverURL)
            updatePendingUploadCount()
            await reloadProjects()
            _ = await retryPendingUploads()
            return errorMessage == nil
        } catch {
            report(error)
            return false
        }
    }

    func speechStream(
        destination: KiboDestination,
        turnID: String,
        fromSample: Int = 0,
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

    func retryFailedWork(_ target: RetryTarget) async {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID,
              !isRetryingFailedWork,
              !isChangingServer else { return }
        let commandServerURL = serverURL
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
            guard commandServerURL == serverURL,
                  projectID == selectedProjectID,
                  conversationID == selectedConversationID else { return }
            status = "Retrying…"
            errorMessage = nil
            await refreshEvents()
        } catch {
            if commandServerURL == serverURL,
               projectID == selectedProjectID,
               conversationID == selectedConversationID {
                report(error)
            }
        }
    }

    func clipAudio(clipID: String) async throws -> Data {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else {
            throw APIError.invalidResponse
        }
        return try await api.clipAudio(
            projectID: projectID, conversationID: conversationID, clipID: clipID
        )
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.projects.isEmpty {
                    // First load failed (e.g. app launched before the network
                    // was up) — keep retrying until projects appear.
                    await self.reloadProjects(quiet: true)
                } else {
                    await self.refreshEvents()
                }
                let interval: Duration = self.events.pendingTurnIDs.isEmpty && !self.isSubmitting
                    ? .seconds(2)
                    : .milliseconds(250)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func restartPollingIfStarted() {
        guard pollTask != nil else { return }
        beginPolling()
    }

    private func report(_ error: Error, quiet: Bool = false) {
        status = "Offline"
        if !quiet { errorMessage = error.localizedDescription }
    }

    private func updatePendingUploadCount() {
        let inventory = spool.inventory()
        pendingUploadCount = inventory.protectedCount(for: serverURL)
        recoveryItemCount = inventory.recoveryItems.count
        pendingClips = inventory.clips
        if recoveryItemCount > 0 && !isUploading && errorMessage == nil {
            status = "Recording recovery needed"
        }
    }

    func refreshRecordingInventory() {
        updatePendingUploadCount()
    }

    private func persist(_ value: String?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func lifecycleClaim() -> LifecycleClaim {
        LifecycleClaim(
            serverVersion: serverVersion,
            projectSelectionVersion: projectSelectionVersion,
            eventSelectionVersion: eventSelectionVersion,
            serverURL: serverURL,
            projectID: selectedProjectID,
            conversationID: selectedConversationID
        )
    }

    private func accepts(_ claim: LifecycleClaim) -> Bool {
        claim.serverVersion == serverVersion
            && claim.projectSelectionVersion == projectSelectionVersion
            && claim.eventSelectionVersion == eventSelectionVersion
            && claim.serverURL == serverURL
            && claim.projectID == selectedProjectID
            && claim.conversationID == selectedConversationID
    }
}
