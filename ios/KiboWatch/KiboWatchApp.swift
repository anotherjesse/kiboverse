import SwiftUI

@main
struct KiboWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchTalkView() }
    }
}

@MainActor
final class WatchStore: ObservableObject {
    static let defaultServerURL = "https://wideboi.stingray-nominal.ts.net/"

    private enum Key {
        static let serverURL = "watchServerURL"
        static let projectID = "watchSelectedProjectID"
        static let conversationID = "watchSelectedConversationID"
    }

    @Published var projects: [KiboProject] = []
    @Published var conversations: [KiboConversation] = []
    @Published var events: [KiboEvent] = []
    @Published var selectedProjectID: String?
    @Published var selectedConversationID: String?
    @Published var status = "Connecting…"
    @Published var errorMessage: String?
    @Published var isUploading = false
    @Published var isSubmitting = false
    @Published var pendingUploadCount = 0

    private let defaults = UserDefaults.standard
    private let spool = WatchPendingUploadSpool()
    private var api: KiboAPI
    private var pollTask: Task<Void, Never>?
    private var uploadTask: Task<Bool, Never>?
    private var hasStarted = false
    private var loadVersion = 0
    private var selectionVersion = 0

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

    init() {
        let raw = UserDefaults.standard.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        let canonical = KiboAPI.canonicalServerURL(raw) ?? Self.defaultServerURL
        api = try! KiboAPI(serverURL: canonical)
        selectedProjectID = defaults.string(forKey: Key.projectID)
        selectedConversationID = defaults.string(forKey: Key.conversationID)
        pendingUploadCount = spool.all().filter { $0.serverURL == canonical }.count
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
        beginPolling()
    }

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
        events = []
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
        events = []
        persist(id, key: Key.conversationID)
        await refreshEvents()
    }

    func refreshEvents(quiet: Bool = false) async {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return }
        let version = selectionVersion
        do {
            let loaded = try await api.events(
                projectID: projectID,
                conversationID: conversationID
            )
            guard version == selectionVersion,
                  projectID == selectedProjectID,
                  conversationID == selectedConversationID else { return }
            events = loaded.events
            updatePendingUploadCount()
            if pendingUploadCount == 0 && !isUploading {
                status = "Live"
                errorMessage = nil
            }
        } catch {
            guard version == selectionVersion else { return }
            if !quiet || events.isEmpty { report(error) }
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
    func submitTurn() async -> String? {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID,
              !isSubmitting else { return nil }
        let destinationKey = "\(projectID)/\(conversationID)"
        guard await retryPendingUploads(destinationKey: destinationKey) else { return nil }
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
            await refreshEvents()
            return turnID
        } catch {
            report(error)
            return nil
        }
    }

    func speech(turnID: String) async throws -> (Data, Int) {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else {
            throw APIError.invalidResponse
        }
        return try await api.speech(
            projectID: projectID,
            conversationID: conversationID,
            turnID: turnID
        )
    }

    func saveServer(_ value: String) async -> Bool {
        guard !isUploading, !isSubmitting else {
            errorMessage = "Wait for the current request to finish."
            return false
        }
        guard pendingUploadCount == 0 else {
            errorMessage = "Let saved recordings finish sending before changing servers."
            return false
        }
        do {
            guard let canonicalURL = KiboAPI.canonicalServerURL(value) else {
                throw APIError.invalidServerURL
            }
            try await api.setServerURL(canonicalURL)
            defaults.set(canonicalURL, forKey: Key.serverURL)
            loadVersion += 1
            selectionVersion += 1
            projects = []
            conversations = []
            events = []
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
                    recordedAt: clip.recordedAt
                )
                spool.remove(clip)
            } catch {
                allSent = false
                status = "Saved on this Watch"
                errorMessage = "Recording saved; sending will retry. \(error.localizedDescription)"
            }
        }
        if allSent { status = "Thought saved" }
        return allSent
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.projects.isEmpty {
                    await self.load()
                } else {
                    await self.refreshEvents(quiet: true)
                }
            }
        }
    }

    private func updatePendingUploadCount() {
        pendingUploadCount = spool.all().filter { $0.serverURL == serverURL }.count
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
