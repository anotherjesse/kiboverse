@preconcurrency import AVFoundation
import Combine
import Foundation

struct WatchLocalRecording: Sendable {
    let id: String
    let url: URL
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
}

struct WatchPendingClip: Codable, Identifiable, Sendable {
    let id: String
    let serverURL: String
    let projectID: String
    let conversationID: String
    let wavFilename: String
    let durationMs: Int
    let peakPct: Int
    let recordedAt: Int
    let enqueuedAtMs: Int64

    var destinationKey: String { "\(projectID)/\(conversationID)" }
}

struct WatchPendingUploadSpool {
    private let fileManager = FileManager.default

    func enqueue(
        recording: WatchLocalRecording,
        serverURL: String,
        projectID: String,
        conversationID: String
    ) throws -> WatchPendingClip {
        let clip = WatchPendingClip(
            id: recording.id,
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID,
            wavFilename: recording.url.lastPathComponent,
            durationMs: recording.durationMs,
            peakPct: recording.peakPct,
            recordedAt: recording.recordedAt,
            enqueuedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
        )
        try JSONEncoder().encode(clip).write(to: metadataURL(for: clip.id), options: .atomic)
        return clip
    }

    func all() -> [WatchPendingClip] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { metadataURL -> WatchPendingClip? in
                guard let data = try? Data(contentsOf: metadataURL),
                      let clip = try? JSONDecoder().decode(WatchPendingClip.self, from: data)
                else { return nil }
                guard fileManager.fileExists(atPath: wavURL(for: clip).path) else {
                    try? fileManager.removeItem(at: metadataURL)
                    return nil
                }
                return clip
            }
            .sorted { ($0.enqueuedAtMs, $0.id) < ($1.enqueuedAtMs, $1.id) }
    }

    func wavURL(for clip: WatchPendingClip) -> URL {
        directory().appendingPathComponent(clip.wavFilename)
    }

    func remove(_ clip: WatchPendingClip) {
        try? fileManager.removeItem(at: metadataURL(for: clip.id))
        try? fileManager.removeItem(at: wavURL(for: clip))
    }

    private func metadataURL(for id: String) -> URL {
        directory().appendingPathComponent("\(id).json")
    }

    private func directory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("WatchPendingRecordings", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
protocol WatchAudioCapturing: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var isRecording: Bool { get }
    var isStarting: Bool { get }
    var level: CGFloat { get }
    var errorMessage: String? { get set }
    func prepare() async
    func start(holdID: UUID) async -> Bool
    func stop(holdID: UUID) -> WatchLocalRecording?
    func cancel(holdID: UUID?)
    func resetAudioObjects()
}

@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject, WatchAudioCapturing,
    @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: CGFloat = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var preparedRecorder: AVAudioRecorder?
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
            let recorder = try makeRecorder()
            guard recorder.prepareToRecord() else { throw WatchRecorderError.couldNotPrepare }
            guard !Task.isCancelled, audioObjectEpoch == epoch else {
                try? FileManager.default.removeItem(at: recorder.url)
                return
            }
            preparedRecorder = recorder
        } catch {
            if audioObjectEpoch == epoch { preparedRecorder = nil }
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
            if let preparedRecorder {
                recorder = preparedRecorder
            } else {
                recorder = try makeRecorder()
            }
            preparedRecorder = nil
            if !recorder.isRecording { recorder.prepareToRecord() }
            guard activeHoldID == holdID, !Task.isCancelled, recorder.record() else {
                try? FileManager.default.removeItem(at: recorder.url)
                throw WatchRecorderError.couldNotStart
            }
            self.recorder = recorder
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

    func stop(holdID: UUID) -> WatchLocalRecording? {
        guard activeHoldID == holdID else { return nil }
        activeHoldID = nil
        guard let recorder else { return nil }
        let durationMs = Int((recorder.currentTime * 1000).rounded())
        let workingURL = recorder.url
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        self.recorder = nil
        level = 0
        isRecording = false

        guard durationMs >= 500 else {
            try? FileManager.default.removeItem(at: workingURL)
            errorMessage = "Hold a little longer to record."
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let finalURL = recordingDirectory().appendingPathComponent("recording-\(id).wav")
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            return WatchLocalRecording(
                id: id,
                url: finalURL,
                durationMs: durationMs,
                peakPct: peakPct,
                recordedAt: Int(Date().timeIntervalSince1970)
            )
        } catch {
            try? FileManager.default.removeItem(at: workingURL)
            errorMessage = "The recording could not be saved. \(error.localizedDescription)"
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
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        level = 0
        isRecording = false
        isStarting = false
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder else { return }
        cancel()
        if !flag { errorMessage = "Recording was interrupted. Please try again." }
    }

    private func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func makeRecorder() throws -> AVAudioRecorder {
        let url = recordingDirectory().appendingPathComponent("working-recording.wav")
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
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        preparedRecorder = nil
        level = 0
        isRecording = false
        isStarting = false
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
