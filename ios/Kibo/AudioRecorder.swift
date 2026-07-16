@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: CGFloat = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recorderLease: ActiveRecordingFileLease?
    private var preparedRecorder: AVAudioRecorder?
    private var preparedRecorderLease: ActiveRecordingFileLease?
    private var meterTask: Task<Void, Never>?
    private var peakPct = 0
    private var activeHoldID: UUID?
    private var startingHoldID: UUID?
    private var isPreparing = false

    /// Prepare the audio session and file writer before the user presses Talk.
    /// This keeps the button-down path short enough to preserve the first word.
    func prepare() async {
        guard recorder == nil, preparedRecorder == nil, !isPreparing, !isStarting else { return }
        isPreparing = true
        defer { isPreparing = false }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed, recorder == nil, preparedRecorder == nil, !isStarting else { return }
        do {
            let (recorder, lease) = try makeRecorder()
            guard recorder.prepareToRecord() else {
                discard(recorder, lease: lease)
                throw RecorderError.couldNotPrepare
            }
            preparedRecorder = recorder
            preparedRecorderLease = lease
        } catch {
            // A cold-start fallback remains available when the user presses.
            preparedRecorder = nil
            preparedRecorderLease = nil
        }
    }

    func start(holdID: UUID) async -> Bool {
        guard !isRecording, !Task.isCancelled else { return false }
        activeHoldID = holdID
        startingHoldID = holdID
        isStarting = true
        var warmRecorder = preparedRecorder
        var warmLease = preparedRecorderLease
        if let preparedRecorder = warmRecorder {
            self.preparedRecorder = nil
            self.preparedRecorderLease = nil
            guard !Task.isCancelled else {
                activeHoldID = nil
                finishStarting(holdID)
                if let warmLease { discard(preparedRecorder, lease: warmLease) }
                return false
            }
            // Playback may have changed the shared route after this recorder was
            // prepared. Try the warm recorder first, then fall back to a fresh one.
            if let warmLease,
               beginRecording(preparedRecorder, lease: warmLease, holdID: holdID) { return true }
            if let warmLease { discard(preparedRecorder, lease: warmLease) }
            warmRecorder = nil
            warmLease = nil
        }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard activeHoldID == holdID, !Task.isCancelled else {
            if activeHoldID == holdID { activeHoldID = nil }
            finishStarting(holdID)
            return false
        }
        guard allowed else {
            activeHoldID = nil
            finishStarting(holdID)
            errorMessage = "Microphone access is required for push to talk."
            return false
        }
        do {
            let (recorder, lease) = try makeRecorder()
            recorder.prepareToRecord()
            guard beginRecording(recorder, lease: lease, holdID: holdID) else {
                discard(recorder, lease: lease)
                throw RecorderError.couldNotStart
            }
            return true
        } catch {
            if activeHoldID == holdID { activeHoldID = nil }
            finishStarting(holdID)
            errorMessage = error.localizedDescription
            isRecording = false
            return false
        }
    }

    func stop(holdID: UUID) -> LocalRecording? {
        guard activeHoldID == holdID else { return nil }
        activeHoldID = nil
        guard let recorder else {
            finishStarting(holdID)
            return nil
        }
        let durationMs = Int((recorder.currentTime * 1000).rounded())
        let workingURL = recorder.url
        let lease = recorderLease
        self.recorder = nil
        recorderLease = nil
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        level = 0
        isRecording = false
        guard durationMs >= 350 else {
            lease?.relinquish()
            try? FileManager.default.removeItem(at: workingURL)
            errorMessage = "Hold a little longer to record."
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let url: URL
        do {
            url = try pendingDirectory().appendingPathComponent("recording-\(id).wav")
            try FileManager.default.moveItem(at: workingURL, to: url)
            lease?.relinquish()
        } catch {
            lease?.abandonForRecovery()
            errorMessage = "The recording could not be finalized and was kept for recovery. \(error.localizedDescription)"
            return nil
        }
        return LocalRecording(
            id: id, url: url, durationMs: durationMs, peakPct: peakPct,
            recordedAt: Int(Date().timeIntervalSince1970)
        )
    }

    func cancel(holdID: UUID? = nil) {
        if let holdID, activeHoldID != holdID { return }
        activeHoldID = nil
        startingHoldID = nil
        isStarting = false
        meterTask?.cancel()
        meterTask = nil
        if let recorder {
            let url = recorder.url
            self.recorder = nil
            recorder.stop()
            recorderLease?.relinquish()
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recorderLease = nil
        level = 0
        isRecording = false
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder else { return }
        preserveForRecovery(holdID: activeHoldID)
        errorMessage = flag
            ? "Recording ended unexpectedly and was kept for recovery."
            : "Recording was interrupted and was kept for recovery."
    }

    func preserveForRecovery(holdID: UUID? = nil) {
        if let holdID, activeHoldID != holdID { return }
        activeHoldID = nil
        startingHoldID = nil
        isStarting = false
        meterTask?.cancel()
        meterTask = nil
        if let recorder {
            self.recorder = nil
            recorder.stop()
            recorderLease?.abandonForRecovery()
        }
        recorder = nil
        recorderLease = nil
        level = 0
        isRecording = false
    }

    private func pendingDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("PendingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func resetAudioObjects() {
        cancel()
        if let preparedRecorder, let preparedRecorderLease {
            discard(preparedRecorder, lease: preparedRecorderLease)
        }
        preparedRecorder = nil
        preparedRecorderLease = nil
    }

    private func makeRecorder() throws -> (AVAudioRecorder, ActiveRecordingFileLease) {
        let filename = "working-recording-\(UUID().uuidString.lowercased()).wav"
        let url = try pendingDirectory().appendingPathComponent(filename)
        let lease = ActiveRecordingFileLease(url: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            return (recorder, lease)
        } catch {
            lease.relinquish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func beginRecording(
        _ recorder: AVAudioRecorder,
        lease: ActiveRecordingFileLease,
        holdID: UUID
    ) -> Bool {
        guard activeHoldID == holdID else {
            return false
        }
        do {
            try lease.markStarted()
        } catch {
            return false
        }
        guard recorder.record() else { return false }
        self.recorder = recorder
        recorderLease = lease
        finishStarting(holdID)
        peakPct = 0
        isRecording = true
        errorMessage = nil
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let normalized = max(0, min(1, pow(10, recorder.peakPower(forChannel: 0) / 20)))
                self.level = CGFloat(normalized)
                self.peakPct = max(self.peakPct, Int((normalized * 100).rounded()))
            }
        }
        return true
    }

    private func discard(_ recorder: AVAudioRecorder, lease: ActiveRecordingFileLease) {
        recorder.stop()
        lease.relinquish()
        try? FileManager.default.removeItem(at: recorder.url)
    }

    private func finishStarting(_ holdID: UUID) {
        guard startingHoldID == holdID else { return }
        startingHoldID = nil
        isStarting = false
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart
    case couldNotPrepare
    var errorDescription: String? {
        switch self {
        case .couldNotStart: "The microphone could not start recording."
        case .couldNotPrepare: "The microphone could not be prepared."
        }
    }
}
