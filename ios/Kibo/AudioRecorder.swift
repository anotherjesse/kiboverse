@preconcurrency import AVFoundation
import Foundation

struct LocalRecording: Sendable {
    let id: String
    let url: URL
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: CGFloat = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var preparedRecorder: AVAudioRecorder?
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
            try configureVoiceSession()
            let recorder = try makeRecorder()
            guard recorder.prepareToRecord() else { throw RecorderError.couldNotPrepare }
            preparedRecorder = recorder
        } catch {
            // A cold-start fallback remains available when the user presses.
            preparedRecorder = nil
        }
    }

    func start(holdID: UUID) async -> Bool {
        guard !isRecording, !Task.isCancelled else { return false }
        activeHoldID = holdID
        startingHoldID = holdID
        isStarting = true
        var warmRecorder = preparedRecorder
        if let preparedRecorder = warmRecorder {
            self.preparedRecorder = nil
            guard !Task.isCancelled else {
                activeHoldID = nil
                finishStarting(holdID)
                try? FileManager.default.removeItem(at: preparedRecorder.url)
                Task { await prepare() }
                return false
            }
            // Playback may have changed the shared route after this recorder was
            // prepared. Try the warm recorder first, then fall back to a fresh one.
            try? configureVoiceSession()
            if beginRecording(preparedRecorder, holdID: holdID) { return true }
            preparedRecorder.stop()
            try? FileManager.default.removeItem(at: preparedRecorder.url)
            warmRecorder = nil
        }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard activeHoldID == holdID, !Task.isCancelled else {
            if activeHoldID == holdID { activeHoldID = nil }
            finishStarting(holdID)
            Task { await prepare() }
            return false
        }
        guard allowed else {
            activeHoldID = nil
            finishStarting(holdID)
            errorMessage = "Microphone access is required for push to talk."
            Task { await prepare() }
            return false
        }
        do {
            try configureVoiceSession()
            let recorder = try makeRecorder()
            recorder.prepareToRecord()
            guard beginRecording(recorder, holdID: holdID) else {
                try? FileManager.default.removeItem(at: recorder.url)
                throw RecorderError.couldNotStart
            }
            return true
        } catch {
            if activeHoldID == holdID { activeHoldID = nil }
            finishStarting(holdID)
            errorMessage = error.localizedDescription
            isRecording = false
            Task { await prepare() }
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
        defer { Task { await self.prepare() } }
        let durationMs = Int((recorder.currentTime * 1000).rounded())
        let workingURL = recorder.url
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        self.recorder = nil
        level = 0
        isRecording = false
        guard durationMs >= 350 else {
            try? FileManager.default.removeItem(at: workingURL)
            errorMessage = "Hold a little longer to record."
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let url: URL
        do {
            url = try pendingDirectory().appendingPathComponent("recording-\(id).wav")
            try FileManager.default.moveItem(at: workingURL, to: url)
        } catch {
            errorMessage = "The recording could not be saved. \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: workingURL)
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
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        level = 0
        isRecording = false
        Task { await prepare() }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder else { return }
        cancel()
        if !flag { errorMessage = "Recording was interrupted. Please try again." }
    }

    private func pendingDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("PendingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func configureVoiceSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    private func makeRecorder() throws -> AVAudioRecorder {
        let url = try pendingDirectory().appendingPathComponent("working-recording.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        return recorder
    }

    private func beginRecording(_ recorder: AVAudioRecorder, holdID: UUID) -> Bool {
        guard activeHoldID == holdID else {
            return false
        }
        guard recorder.record() else { return false }
        self.recorder = recorder
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
