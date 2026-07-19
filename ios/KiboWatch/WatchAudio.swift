@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject, AudioCapturing,
    @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: CGFloat = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recorderLease: ActiveRecordingFileLease?
    private var preparedRecorder: AVAudioRecorder?
    private var preparedRecorderLease: ActiveRecordingFileLease?
    private var meterTask: Task<Void, Never>?
    private var activeHoldID: UUID?
    private var isPreparing = false
    private var peakPct = 0
    private var audioObjectEpoch = UUID()

    func prepare() async {
        guard recorder == nil, preparedRecorder == nil, !isPreparing, !isStarting else { return }
        let epoch = audioObjectEpoch
        isPreparing = true
        defer {
            if audioObjectEpoch == epoch { isPreparing = false }
        }
        guard await requestPermission() else { return }
        guard !Task.isCancelled, audioObjectEpoch == epoch else { return }
        do {
            let (recorder, lease) = try makeRecorder()
            guard recorder.prepareToRecord() else {
                discard(recorder, lease: lease)
                throw WatchRecorderError.couldNotPrepare
            }
            guard !Task.isCancelled, audioObjectEpoch == epoch else {
                discard(recorder, lease: lease)
                return
            }
            preparedRecorder = recorder
            preparedRecorderLease = lease
        } catch {
            if audioObjectEpoch == epoch {
                preparedRecorder = nil
                preparedRecorderLease = nil
            }
        }
    }

    func start(holdID: UUID) async -> Bool {
        guard !isRecording, !isStarting else { return false }
        activeHoldID = holdID
        isStarting = true
        defer { isStarting = false }

        guard await requestPermission() else {
            if activeHoldID == holdID { activeHoldID = nil }
            errorMessage = "Microphone access is required for push to talk."
            return false
        }
        guard activeHoldID == holdID, !Task.isCancelled else { return false }

        do {
            let recorder: AVAudioRecorder
            let lease: ActiveRecordingFileLease
            if let preparedRecorder, let preparedRecorderLease {
                recorder = preparedRecorder
                lease = preparedRecorderLease
            } else {
                (recorder, lease) = try makeRecorder()
            }
            preparedRecorder = nil
            preparedRecorderLease = nil
            if !recorder.isRecording { recorder.prepareToRecord() }
            guard activeHoldID == holdID, !Task.isCancelled else {
                discard(recorder, lease: lease)
                throw WatchRecorderError.couldNotStart
            }
            do {
                try lease.markStarted()
            } catch {
                discard(recorder, lease: lease)
                throw WatchRecorderError.couldNotStart
            }
            guard recorder.record() else {
                discard(recorder, lease: lease)
                throw WatchRecorderError.couldNotStart
            }
            self.recorder = recorder
            recorderLease = lease
            peakPct = 0
            level = 0
            isRecording = true
            errorMessage = nil
            startMetering(recorder)
            return true
        } catch {
            if activeHoldID == holdID { activeHoldID = nil }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stop(holdID: UUID) -> LocalRecording? {
        guard activeHoldID == holdID else { return nil }
        activeHoldID = nil
        guard let recorder else { return nil }
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

        guard durationMs >= 500 else {
            lease?.relinquish()
            try? FileManager.default.removeItem(at: workingURL)
            errorMessage = "Hold a little longer to record."
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let finalURL = recordingDirectory().appendingPathComponent("recording-\(id).wav")
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            lease?.relinquish()
            return LocalRecording(
                id: id,
                url: finalURL,
                durationMs: durationMs,
                peakPct: peakPct,
                recordedAt: Int(Date().timeIntervalSince1970)
            )
        } catch {
            lease?.abandonForRecovery()
            errorMessage = "The recording could not be finalized and was kept for recovery. \(error.localizedDescription)"
            return nil
        }
    }

    func cancel(holdID: UUID? = nil) {
        if let holdID, activeHoldID != holdID { return }
        activeHoldID = nil
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
        isStarting = false
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
        isStarting = false
    }

    private func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func makeRecorder() throws -> (AVAudioRecorder, ActiveRecordingFileLease) {
        let filename = "working-recording-\(UUID().uuidString.lowercased()).wav"
        let url = recordingDirectory().appendingPathComponent(filename)
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

    private func startMetering(_ recorder: AVAudioRecorder) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.recorder === recorder else { return }
                recorder.updateMeters()
                let normalized = max(0, min(1, pow(10, recorder.peakPower(forChannel: 0) / 20)))
                self.level = CGFloat(normalized)
                self.peakPct = max(self.peakPct, Int((normalized * 100).rounded()))
            }
        }
    }

    private func recordingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("WatchPendingRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func resetAudioObjects() {
        audioObjectEpoch = UUID()
        isPreparing = false
        activeHoldID = nil
        meterTask?.cancel()
        meterTask = nil
        if let recorder {
            let url = recorder.url
            recorder.stop()
            recorderLease?.relinquish()
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recorderLease = nil
        if let preparedRecorder, let preparedRecorderLease {
            discard(preparedRecorder, lease: preparedRecorderLease)
        }
        preparedRecorder = nil
        preparedRecorderLease = nil
        level = 0
        isRecording = false
        isStarting = false
    }

    private func discard(_ recorder: AVAudioRecorder, lease: ActiveRecordingFileLease) {
        recorder.stop()
        lease.relinquish()
        try? FileManager.default.removeItem(at: recorder.url)
    }
}

private enum WatchRecorderError: LocalizedError {
    case couldNotStart
    case couldNotPrepare

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "The microphone could not start recording."
        case .couldNotPrepare: "The microphone could not be prepared."
        }
    }
}
