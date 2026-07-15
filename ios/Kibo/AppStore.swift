import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    private struct UploadRunResult {
        let attemptedIDs: Set<String>
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
    @Published var pendingUploadCount = 0
    @Published var status = "Connecting…"
    @Published var errorMessage: String?

    private var api: KiboAPI
    private var pollTask: Task<Void, Never>?
    private var uploadTask: (id: UUID, task: Task<UploadRunResult, Never>)?
    private let spool = PendingUploadSpool()
    private var serverVersion = 0
    private var projectSelectionVersion = 0
    private var eventSelectionVersion = 0
    private var eventRequestVersion = 0

    init() {
        let rawURL = UserDefaults.standard.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        let savedURL = KiboAPI.canonicalServerURL(rawURL) ?? Self.defaultServerURL
        serverURL = savedURL
        api = (try? KiboAPI(serverURL: savedURL)) ?? (try! KiboAPI(serverURL: Self.defaultServerURL))
        selectedProjectID = UserDefaults.standard.string(forKey: Key.projectID)
        selectedConversationID = UserDefaults.standard.string(forKey: Key.conversationID)
        pendingUploadCount = spool.all().filter { $0.serverURL == savedURL }.count
    }

    deinit {
        pollTask?.cancel()
        uploadTask?.task.cancel()
    }

    var selectedProject: KiboProject? { projects.first { $0.id == selectedProjectID } }
    var selectedConversation: KiboConversation? { conversations.first { $0.id == selectedConversationID } }
    var timeline: [TimelineItem] { events.timeline() }
    var isAskingKibo: Bool { isSubmitting || !events.pendingTurnIDs.isEmpty }

    func start() async {
        await reloadProjects()
        _ = await retryPendingUploads()
        beginPolling()
    }

    func reloadProjects() async {
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
            report(error)
        }
    }

    func selectProject(_ id: String?) async {
        guard selectedProjectID != id || conversations.isEmpty else { return }
        projectSelectionVersion += 1
        eventSelectionVersion += 1
        let version = projectSelectionVersion
        selectedProjectID = id
        selectedConversationID = nil
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
            guard version == eventSelectionVersion,
                  requestVersion == eventRequestVersion,
                  project == selectedProjectID, conversation == selectedConversationID else { return }
            report(error, quiet: !events.isEmpty)
        }
    }

    func createProject(name: String) async {
        do {
            let project = try await api.createProject(name: name)
            await reloadProjects()
            await selectProject(project.id)
        } catch { report(error) }
    }

    func createConversation(name: String? = nil) async {
        guard let projectID = selectedProjectID else { return }
        do {
            let conversation = try await api.createConversation(projectID: projectID, name: name)
            let loaded = try await api.conversations(projectID: projectID)
            guard projectID == selectedProjectID else { return }
            conversations = loaded
            await selectConversation(conversation.id)
        } catch { report(error) }
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
            Task {
                _ = await retryPendingUploads(destinationKey: "\(projectID)/\(conversationID)")
                await refreshEvents()
            }
        } catch {
            report(error)
        }
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
            updatePendingUploadCount()
            isUploading = false
        }
        var allSent = true
        for clip in pending {
            do {
                try await api.uploadClip(
                    fileURL: spool.wavURL(for: clip),
                    projectID: clip.projectID, conversationID: clip.conversationID,
                    clipID: clip.id, durationMs: clip.durationMs,
                    peakPct: clip.peakPct, recordedAt: clip.recordedAt
                )
                spool.remove(clip)
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
        for clip in spool.all() where clip.serverURL == serverURL { spool.remove(clip) }
        updatePendingUploadCount()
        errorMessage = nil
        status = "Saved recordings discarded"
    }

    @discardableResult
    func submitTurn() async -> String? {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else { return nil }
        guard !isUploading, !isSubmitting else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        let destination = "\(projectID)/\(conversationID)"
        guard await retryPendingUploads(destinationKey: destination) else { return nil }
        guard !spool.all().contains(where: {
            $0.serverURL == serverURL && $0.destinationKey == destination
        }) else { return nil }
        status = "Kibo is thinking…"
        let commandKey = "pendingTurnID.\(serverURL).\(destination)"
        let turnID = UserDefaults.standard.string(forKey: commandKey)
            ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(turnID, forKey: commandKey)
        do {
            try await api.submitTurn(
                projectID: projectID, conversationID: conversationID,
                turnID: turnID
            )
            UserDefaults.standard.removeObject(forKey: commandKey)
            await refreshEvents()
            return turnID
        } catch {
            report(error)
            return nil
        }
    }

    func updateServerURL(_ value: String) async -> Bool {
        guard !isUploading, !isSubmitting else {
            errorMessage = "Wait for the current upload or Kibo request to finish before changing servers."
            return false
        }
        guard pendingUploadCount == 0 else {
            errorMessage = "Retry or discard saved recordings before changing servers."
            return false
        }
        do {
            guard let canonicalURL = KiboAPI.canonicalServerURL(value) else {
                throw APIError.invalidServerURL
            }
            try await api.setServerURL(canonicalURL)
            serverURL = canonicalURL
            UserDefaults.standard.set(serverURL, forKey: Key.serverURL)
            updatePendingUploadCount()
            serverVersion += 1
            projectSelectionVersion += 1
            eventSelectionVersion += 1
            projects = []
            conversations = []
            events = []
            await reloadProjects()
            _ = await retryPendingUploads()
            return errorMessage == nil
        } catch {
            report(error)
            return false
        }
    }

    func speech(turnID: String) async throws -> (Data, Int) {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else {
            throw APIError.invalidResponse
        }
        return try await api.speech(projectID: projectID, conversationID: conversationID, turnID: turnID)
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
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshEvents()
            }
        }
    }

    private func report(_ error: Error, quiet: Bool = false) {
        status = "Offline"
        if !quiet { errorMessage = error.localizedDescription }
    }

    private func updatePendingUploadCount() {
        pendingUploadCount = spool.all().filter { $0.serverURL == serverURL }.count
    }

    private func persist(_ value: String?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
