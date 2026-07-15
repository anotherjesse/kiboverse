@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol SpeechAudioPlaying: AnyObject {
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var didFinish: (() -> Void)? { get set }
    func prepareToPlay()
    func play() -> Bool
    func stop()
}

@MainActor
private final class SystemSpeechAudioPlayer: NSObject, SpeechAudioPlaying, @preconcurrency AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var didFinish: (() -> Void)?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
    }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    func prepareToPlay() { player.prepareToPlay() }
    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish?()
    }
}

@MainActor
final class SpeechPlayer: ObservableObject {
    typealias PlayerFactory = @MainActor (Data) throws -> any SpeechAudioPlaying
    typealias SessionActivator = @MainActor (_ reset: Bool) throws -> Void

    private struct Asset {
        let id: String
        let data: Data
    }

    private struct InterruptionSnapshot {
        let asset: Asset
        let time: TimeInterval
    }

    @Published private(set) var playingID: String?
    @Published private(set) var loadingID: String?
    @Published var errorMessage: String?
    private var player: (any SpeechAudioPlaying)?
    private var currentAsset: Asset?
    private var interruptionSnapshot: InterruptionSnapshot?
    private var requestID = UUID()
    private var loadingTask: Task<Void, Never>?
    private var recordingInterruptionActive = false
    private let makePlayer: PlayerFactory
    private let activateSession: SessionActivator

    init(
        makePlayer: @escaping PlayerFactory = { try SystemSpeechAudioPlayer(data: $0) },
        activateSession: @escaping SessionActivator = SpeechPlayer.activateSystemSession
    ) {
        self.makePlayer = makePlayer
        self.activateSession = activateSession
    }

    func toggleReply(turnID: String, store: AppStore) {
        let id = "reply-\(turnID)"
        toggle(id: id) {
            let (pcm, rate) = try await store.speech(turnID: turnID)
            return Self.wav(pcm: pcm, sampleRate: rate)
        }
    }

    func playReply(turnID: String, store: AppStore) {
        let id = "reply-\(turnID)"
        guard playingID != id, loadingID != id else { return }
        play(id: id) {
            let (pcm, rate) = try await store.speech(turnID: turnID)
            return Self.wav(pcm: pcm, sampleRate: rate)
        }
    }

    func toggleClip(clipID: String, store: AppStore) {
        toggle(id: "clip-\(clipID)") { try await store.clipAudio(clipID: clipID) }
    }

    private func toggle(id: String, load: @escaping @MainActor () async throws -> Data) {
        if playingID == id || loadingID == id { stop(); return }
        play(id: id, load: load)
    }

    private func play(id: String, load: @escaping @MainActor () async throws -> Data) {
        stopPlayback()
        let requestID = UUID()
        self.requestID = requestID
        loadingID = id
        loadingTask = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                guard let self, self.requestID == requestID else { return }
                self.loadingTask = nil
                self.loadingID = nil
                self.errorMessage = nil
                try self.playLoadedAudio(id: id, data: data)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.requestID == requestID else { return }
                self.player = nil
                self.currentAsset = nil
                self.interruptionSnapshot = nil
                self.playingID = nil
                self.loadingTask = nil
                self.loadingID = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Mirrors the Pi voiceflow: silence speech before the microphone opens.
    /// Audio which finishes loading during the hold stays queued here.
    func pauseForRecording() {
        guard !recordingInterruptionActive else { return }
        recordingInterruptionActive = true
        guard let asset = currentAsset, playingID == asset.id else { return }
        let time = player?.currentTime ?? 0
        interruptionSnapshot = InterruptionSnapshot(asset: asset, time: time)
        player?.stop()
        player = nil
    }

    /// Continue interrupted speech with a short rewind so the sentence remains
    /// understandable after the inline recording interruption.
    func resumeAfterRecording(rewindBy seconds: TimeInterval = 1) {
        guard recordingInterruptionActive else { return }
        recordingInterruptionActive = false
        guard let snapshot = interruptionSnapshot else { return }
        interruptionSnapshot = nil
        do {
            try startFreshPlayback(
                asset: snapshot.asset,
                at: Self.rewoundTime(snapshot.time, by: seconds),
                resettingSession: true
            )
            errorMessage = nil
        } catch {
            self.player = nil
            currentAsset = nil
            playingID = nil
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        recordingInterruptionActive = false
        stopPlayback()
    }

    private func stopPlayback() {
        requestID = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        player?.stop()
        player = nil
        currentAsset = nil
        interruptionSnapshot = nil
        playingID = nil
        loadingID = nil
    }

    /// Internal so the player lifecycle can be regression-tested without a network request.
    func playLoadedAudio(id: String, data: Data) throws {
        let asset = Asset(id: id, data: data)
        currentAsset = asset
        playingID = id
        if recordingInterruptionActive {
            interruptionSnapshot = InterruptionSnapshot(asset: asset, time: 0)
        } else {
            try startFreshPlayback(asset: asset, at: 0, resettingSession: false)
        }
    }

    private func startFreshPlayback(
        asset: Asset,
        at time: TimeInterval,
        resettingSession: Bool
    ) throws {
        try activateSession(resettingSession)
        let player = try makePlayer(asset.data)
        player.currentTime = max(0, time)
        player.prepareToPlay()
        player.didFinish = { [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.player = nil
            self.currentAsset = nil
            self.interruptionSnapshot = nil
            self.playingID = nil
        }
        self.player = player
        currentAsset = asset
        playingID = asset.id
        guard player.play() else {
            self.player = nil
            throw PlayerError.couldNotPlay
        }
    }

    private static func activateSystemSession(reset: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // Recording and playback use the same category, but a full activation cycle
        // gives every newly-created player a clean route after the microphone closes.
        if reset {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try? session.overrideOutputAudioPort(.none)
        try session.setActive(true)
    }

    static func wav(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + pcm.count))
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(16); append16(1); append16(1)
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append16(2); append16(16)
        data.append("data".data(using: .ascii)!)
        append(UInt32(pcm.count)); data.append(pcm)
        return data
    }

    static func rewoundTime(_ currentTime: TimeInterval, by seconds: TimeInterval = 1) -> TimeInterval {
        max(0, currentTime - seconds)
    }
}

private enum PlayerError: LocalizedError {
    case couldNotPlay
    var errorDescription: String? { "The reply audio could not be played." }
}
