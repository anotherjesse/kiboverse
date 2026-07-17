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
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
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
    /// Bumped when a server change commits: an intake task (normalize →
    /// spool) that began under an older generation is refused at enqueue —
    /// a stalled decode finishing after a timed-out drain must never spool
    /// an attachment for a server the user has left.
    private var intakeGeneration = 0
    /// How long an ask or server change waits on in-flight intake before
    /// proceeding without it: a hung decoder must degrade (its image joins
    /// a later turn, or is refused at enqueue after a server change) rather
    /// than wedge Ask and Settings forever. Tests shorten this.
    var intakeDrainTimeout: Duration = .seconds(30)
    private let spool = PendingUploadSpool(directoryName: PendingUploadSpool.phoneDirectoryName)
    private let attachmentSpool: PendingAttachmentSpool
    private let destinationCacheStore: DestinationCacheStore?
    private let normalizeImage: @Sendable (Data, Date) throws -> NormalizedImage
    private let imageCache = ConversationImageCache()
    private var clipRecoveryItemCount = 0
    private var attachmentRecoveryItemCount = 0
    private var isCreating = false
    private var serverVersion = 0
    private var projectSelectionVersion = 0
    private var eventSelectionVersion = 0
    private var eventRequestVersion = 0

    init(
        session: URLSession = .shared,
        attachmentSpool: PendingAttachmentSpool = PendingAttachmentSpool.mainApp(),
        destinationCacheStore: DestinationCacheStore? = DestinationCacheStore.appGroup(),
        normalizeImage: @escaping @Sendable (Data, Date) throws -> NormalizedImage = {
            try ImageNormalizer.normalize(data: $0, intakeDate: $1)
        }
    ) {
        let rawURL = UserDefaults.standard.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        let savedURL = KiboAPI.canonicalServerURL(rawURL) ?? Self.defaultServerURL
        serverURL = savedURL
        api = (try? KiboAPI(serverURL: savedURL, session: session))
            ?? (try! KiboAPI(serverURL: Self.defaultServerURL, session: session))
        self.attachmentSpool = attachmentSpool
        self.destinationCacheStore = destinationCacheStore
        self.normalizeImage = normalizeImage
        selectedProjectID = UserDefaults.standard.string(forKey: Key.projectID)
        selectedConversationID = UserDefaults.standard.string(forKey: Key.conversationID)
        let inventory = spool.inventory()
        let attachmentInventory = attachmentSpool.inventory()
        pendingUploadCount = inventory.protectedCount(for: savedURL)
            + attachmentInventory.protectedCount(for: savedURL)
        clipRecoveryItemCount = inventory.recoveryItems.count
        attachmentRecoveryItemCount = attachmentInventory.recoveryItems.count
        recoveryItemCount = clipRecoveryItemCount + attachmentRecoveryItemCount
        pendingClips = inventory.clips
        pendingAttachments = attachmentInventory.attachments
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
    /// Media the next "Ask Kibo" would claim: clips and images already on the
    /// server that no turn has claimed, plus recordings and attachments queued
    /// on this device for the SELECTED conversation. Items spooled for other
    /// conversations and recovery items never count — an ask cannot submit
    /// those, and advertising them would re-enable the 409 path.
    var askableItemCount: Int {
        events.unclaimedMediaCount + localAskableClipCount + localAskableAttachmentCount
    }
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
    /// Locally spooled image attachments destined for the selected
    /// conversation on the current server.
    var localAskableAttachmentCount: Int {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return 0 }
        let destinationKey = "\(projectID)/\(conversationID)"
        let serverURL = self.serverURL
        return pendingAttachments.lazy.filter {
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
        attachmentSpool.sweep()
        updatePendingUploadCount()
        _ = await retryPendingUploads()
        beginPolling()
    }

    /// Foreground maintenance: run the attachment spool sweep (staging GC and
    /// migration-root drain — the seam the share extension will rely on) and
    /// kick the upload ladder for anything deposited while the app was away.
    func resumePendingWork() {
        attachmentSpool.sweep()
        updatePendingUploadCount()
        Task { [weak self] in _ = await self?.retryPendingUploads() }
    }

    func reloadProjects(quiet: Bool = false) async {
        let version = serverVersion
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await api.projects()
            guard version == serverVersion else { return }
            projects = loaded
            persistDestinationCache()
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
        persistDestinationCache()
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

    /// Normalize → spool → upload one captured image (the single-shot camera
    /// path). Registered in `recordingTasks` so a swipe-up ask
    /// (`waitForRecordingTasks`) cannot race its own image into the next
    /// turn — the same contract as voice clips. The intake timestamp and
    /// generation are captured HERE, at the moment the user added the image.
    /// Multi-image picker selections go through `beginImageIntake` instead.
    @discardableResult
    func queueImage(data: Data, source: String) -> Task<Void, Never>? {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else {
            errorMessage = "Choose a project and conversation first."
            return nil
        }
        let serverURL = self.serverURL
        let normalize = normalizeImage
        let intakeDate = Date()
        let generation = intakeGeneration
        let taskID = UUID()
        let task = Task { [weak self] in
            defer { self?.recordingTasks[taskID] = nil }
            guard let self else { return }
            do {
                let normalized = try await Task.detached(priority: .userInitiated) {
                    try normalize(data, intakeDate)
                }.value
                guard !Task.isCancelled else { return }
                guard generation == intakeGeneration else {
                    errorMessage = "A photo was still being added when the server changed, so it was not saved."
                    return
                }
                _ = try attachmentSpool.enqueue(
                    image: normalized, serverURL: serverURL,
                    projectID: projectID, conversationID: conversationID,
                    source: source
                )
                updatePendingUploadCount()
                status = "Saved locally · sending…"
                _ = await retryPendingUploads(destinationKey: "\(projectID)/\(conversationID)")
                await refreshEvents()
            } catch {
                report(error)
            }
        }
        recordingTasks[taskID] = task
        return task
    }

    /// Begin one picked-photos batch, called BEFORE the picker dismisses.
    /// The destination and a single intake timestamp are captured here for
    /// the whole selection, and one gate is registered in `recordingTasks`
    /// and held until `finish()` — so an Ask (`waitForRecordingTasks` →
    /// `submitTurn`) or a navigation mid-batch can neither split the
    /// selection across turns nor redirect later images. Uploads are
    /// decoupled from per-image intake: they start once, after the last
    /// image spools (an Ask in the meantime drains the same spool itself).
    func beginImageIntake(source: String) -> ImageIntakeBatch? {
        guard let projectID = selectedProjectID, let conversationID = selectedConversationID else {
            errorMessage = "Choose a project and conversation first."
            return nil
        }
        let batch = ImageIntakeBatch(
            store: self, serverURL: serverURL,
            projectID: projectID, conversationID: conversationID,
            intakeDate: Date(), generation: intakeGeneration, source: source
        )
        let gateID = UUID()
        recordingTasks[gateID] = Task { [weak self] in
            defer { self?.recordingTasks[gateID] = nil }
            await batch.waitUntilFinished()
            guard let self else { return }
            _ = await self.retryPendingUploads(destinationKey: batch.destinationKey)
            await self.refreshEvents()
        }
        return batch
    }

    /// Normalize and spool one batch payload against the batch-captured
    /// destination and intake timestamp, refusing stale generations at
    /// enqueue exactly like the single-shot path.
    fileprivate func spoolBatchImage(_ data: Data, into batch: ImageIntakeBatch) async {
        let normalize = normalizeImage
        let intakeDate = batch.intakeDate
        do {
            let normalized = try await Task.detached(priority: .userInitiated) {
                try normalize(data, intakeDate)
            }.value
            guard !Task.isCancelled else { return }
            guard batch.generation == intakeGeneration else {
                errorMessage = "A photo was still being added when the server changed, so it was not saved."
                return
            }
            _ = try attachmentSpool.enqueue(
                image: normalized, serverURL: batch.serverURL,
                projectID: batch.projectID, conversationID: batch.conversationID,
                source: batch.source
            )
            updatePendingUploadCount()
            status = "Saved locally · sending…"
        } catch {
            report(error)
        }
    }

    /// Verified conversation image for the timeline: memory → disk → server,
    /// with the payload hashed against the event digest before it is cached.
    func image(imageID: String, sha256: String) async -> UIImage? {
        guard let projectID = selectedProjectID,
              let conversationID = selectedConversationID else { return nil }
        let api = self.api
        return try? await imageCache.image(sha256: sha256) {
            try await api.imageContent(
                projectID: projectID, conversationID: conversationID, imageID: imageID
            )
        }
    }

    /// Ask/server-change gate (and test seam): queued recording work is
    /// explicit rather than an untracked task that can leak requests into a
    /// later lifecycle. BOUNDED — a hung decoder must not wedge Ask or
    /// server changes forever, so after the timeout the caller proceeds and
    /// the intake-generation token refuses any stale spool at enqueue.
    /// Returns false when the timeout expired with intake still in flight.
    @discardableResult
    func waitForRecordingTasks(upTo timeout: Duration? = nil) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout ?? intakeDrainTimeout)
        while !recordingTasks.isEmpty {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
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

        let matchingClipIDs = spool.all().filter {
            $0.serverURL == serverURL && (destinationKey == nil || $0.destinationKey == destinationKey)
        }.map(\.id)
        let matchingAttachmentIDs = attachmentSpool.all().filter {
            $0.serverURL == serverURL && (destinationKey == nil || $0.destinationKey == destinationKey)
        }.map(\.id)
        let matching = matchingClipIDs + matchingAttachmentIDs
        let candidates = matching.filter { !attemptedIDs.contains($0) }
        guard !candidates.isEmpty else {
            updatePendingUploadCount()
            return matching.isEmpty
        }
        let candidateIDs = Set(candidates)
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
        let pendingImages = attachmentSpool.all().filter {
            $0.serverURL == serverURL && candidateIDs.contains($0.id)
        }
        guard !pending.isEmpty || !pendingImages.isEmpty else {
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
        for attachment in pendingImages {
            do {
                try await api.uploadImage(
                    fileURL: attachmentSpool.payloadURL(for: attachment),
                    projectID: attachment.projectID, conversationID: attachment.conversationID,
                    imageID: attachment.id, mime: attachment.mime,
                    width: attachment.width, height: attachment.height,
                    recordedAt: attachment.recordedAt, caption: attachment.caption,
                    expectedSHA256: attachment.sha256
                )
                attachmentSpool.remove(attachment)
            } catch APIError.localAttachmentChanged {
                allSent = false
                do {
                    try attachmentSpool.quarantine(
                        attachment,
                        reason: .payloadChecksumMismatch,
                        detail: "The image no longer matches the checksum saved when it was queued."
                    )
                    status = "Photo recovery needed"
                    errorMessage = "A saved photo changed before upload. Review it in Settings."
                } catch {
                    status = "Saved on this iPhone"
                    errorMessage = "The photo changed and could not be quarantined. \(error.localizedDescription)"
                }
            } catch let APIError.server(code, _)
                where code == 400 || code == 404 || code == 409 || code == 413 {
                // A permanent rejection retries into the identical rejection
                // forever and wedges submitTurn's drain guard for this
                // conversation — quarantine instead so the user can review
                // and discard it (the audio spool has no analog: the server
                // never size/format-rejects a WAV the recorder produced).
                // 404 is in the class because kibod 404s unknown
                // conversations: a destination deleted after intake can
                // never start succeeding.
                allSent = false
                do {
                    try attachmentSpool.quarantine(
                        attachment,
                        reason: .serverRejected,
                        detail: "The server rejected this photo (HTTP \(code)). It will not be retried."
                    )
                    status = "Photo recovery needed"
                    errorMessage = "The server rejected a saved photo. Review it in Settings."
                } catch {
                    status = "Saved on this iPhone"
                    errorMessage = "The photo was rejected and could not be quarantined. \(error.localizedDescription)"
                }
            } catch {
                allSent = false
                status = "Saved on this iPhone"
                errorMessage = "Photo saved locally; upload will retry. \(error.localizedDescription)"
            }
        }
        if allSent && !(pending.isEmpty && pendingImages.isEmpty) { status = "Thought saved" }
        return UploadRunResult(
            attemptedIDs: Set(pending.map(\.id)).union(pendingImages.map(\.id))
        )
    }

    /// Bulk by design (pre-existing Phase C scope): this is also the ONLY
    /// exit for quarantined photos — discarding recovery items is
    /// all-or-nothing, there is no per-item discard UI.
    func discardPendingUploads() {
        guard !isUploading else {
            errorMessage = "Wait for the current upload to finish before discarding recordings."
            return
        }
        let inventory = spool.inventory()
        let attachmentInventory = attachmentSpool.inventory()
        for clip in inventory.clips where clip.serverURL == serverURL { spool.remove(clip) }
        // Attachments are removed regardless of their pinned server: the
        // share extension can deposit a package against a serverURL the app
        // has since left, and such a package is invisible to every counter
        // and retry pass (they filter by the CURRENT server) — without this
        // it would survive discard forever as an invisible black hole.
        // Clips keep the filter: only this app enqueues them, always under
        // the live server, and a switch is blocked while any are pending.
        for attachment in attachmentInventory.attachments {
            attachmentSpool.remove(attachment)
        }
        do {
            for recovery in inventory.recoveryItems { try spool.remove(recovery) }
            for recovery in attachmentInventory.recoveryItems { try attachmentSpool.remove(recovery) }
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
            status = clipRecoveryItemCount > 0
                ? "Resolve recording recovery in Settings before asking Kibo"
                : "Resolve photo recovery in Settings before asking Kibo"
            return nil
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let destination = "\(projectID)/\(conversationID)"
        guard await retryPendingUploads(destinationKey: destination) else { return nil }
        guard !Task.isCancelled, accepts(claim) else { return nil }
        updatePendingUploadCount()
        guard recoveryItemCount == 0 else {
            status = clipRecoveryItemCount > 0
                ? "Resolve recording recovery in Settings before asking Kibo"
                : "Resolve photo recovery in Settings before asking Kibo"
            return nil
        }
        guard !spool.all().contains(where: {
            $0.serverURL == claim.serverURL && $0.destinationKey == destination
        }), !attachmentSpool.all().contains(where: {
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
        // An in-flight intake task (normalize → spool) is a pending upload
        // that just hasn't reached the spool yet: switching servers under it
        // would strand its attachment on the old server URL, invisible to the
        // new server's pending count. Drain intake before taking inventory —
        // boundedly: if a hung decoder outlives the timeout, the switch
        // proceeds and the generation bump below refuses the stale intake at
        // enqueue, so nothing can spool for the abandoned server.
        await waitForRecordingTasks()
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
            intakeGeneration += 1
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
            // The extension's world view must not outlive the server that
            // produced it: an old-server cache would keep offering (and
            // accepting photos for) destinations the app has left, even when
            // the new server is unreachable and the reload below fails.
            // Reset to empty-for-the-new-server the moment the switch
            // commits; successful loads repopulate it, and until then the
            // extension honestly says "open Kibo first".
            destinationCacheStore?.save(DestinationCache(serverURL: canonicalURL))
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
        let attachmentInventory = attachmentSpool.inventory()
        pendingUploadCount = inventory.protectedCount(for: serverURL)
            + attachmentInventory.protectedCount(for: serverURL)
        clipRecoveryItemCount = inventory.recoveryItems.count
        attachmentRecoveryItemCount = attachmentInventory.recoveryItems.count
        recoveryItemCount = clipRecoveryItemCount + attachmentRecoveryItemCount
        pendingClips = inventory.clips
        pendingAttachments = attachmentInventory.attachments
        if recoveryItemCount > 0 && !isUploading && errorMessage == nil {
            status = clipRecoveryItemCount > 0
                ? "Recording recovery needed"
                : "Photo recovery needed"
        }
    }

    func refreshRecordingInventory() {
        updatePendingUploadCount()
    }

    private func persist(_ value: String?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Persist the known project/conversation list plus the current selection
    /// into the app-group container — the share extension's entire world view
    /// (it never touches the network; this cache IS its destination picker).
    /// Best-effort by design: without the app group there is no extension to
    /// feed, so there is no store and nothing to do.
    private func persistDestinationCache() {
        guard let destinationCacheStore else { return }
        var cache = destinationCacheStore.load() ?? DestinationCache(serverURL: serverURL)
        if cache.serverURL != serverURL {
            // Cached destinations are only meaningful on the server that
            // produced them; a server switch starts the cache over.
            cache = DestinationCache(serverURL: serverURL)
        }
        cache.apply(projects: projects.map { (id: $0.id, name: $0.name) })
        if let projectID = selectedProjectID, !conversations.isEmpty {
            cache.apply(
                conversations: conversations.map { (id: $0.id, name: $0.name) },
                projectID: projectID
            )
        }
        cache.select(projectID: selectedProjectID, conversationID: selectedConversationID)
        destinationCacheStore.save(cache)
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

/// One picked-photos selection, begun via `AppStore.beginImageIntake` BEFORE
/// the picker dismisses. Destination, intake timestamp, and generation are
/// captured once for the whole batch; a single gate in `recordingTasks` is
/// held until `finish()`, so an Ask or navigation mid-batch can neither
/// split the selection across turns nor redirect later images — and every
/// image in the batch shares the moment the user picked it as `recorded_at`.
@MainActor
final class ImageIntakeBatch {
    fileprivate let serverURL: String
    fileprivate let projectID: String
    fileprivate let conversationID: String
    fileprivate let generation: Int
    fileprivate let source: String
    let intakeDate: Date
    private weak var store: AppStore?
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init(
        store: AppStore,
        serverURL: String,
        projectID: String,
        conversationID: String,
        intakeDate: Date,
        generation: Int,
        source: String
    ) {
        self.store = store
        self.serverURL = serverURL
        self.projectID = projectID
        self.conversationID = conversationID
        self.intakeDate = intakeDate
        self.generation = generation
        self.source = source
    }

    var destinationKey: String { "\(projectID)/\(conversationID)" }

    /// Normalize and spool one payload against the batch-captured
    /// destination. Serial end-to-end by construction: the caller loads the
    /// next provider's bytes only after this returns, so at most one source
    /// `Data` is alive at a time.
    func add(_ data: Data) async {
        guard !isFinished, let store else { return }
        await store.spoolBatchImage(data, into: self)
    }

    /// Release the gate: intake for this selection is complete (idempotent).
    /// The gate task then kicks one upload pass for the whole batch.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    fileprivate func waitUntilFinished() async {
        if isFinished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
