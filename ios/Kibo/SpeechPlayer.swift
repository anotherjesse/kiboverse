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
    typealias RendererFactory = @MainActor (_ sampleRate: Int, _ startSample: Int) throws -> any SpeechRendering
    typealias SessionActivator = @MainActor (_ intent: AudioSessionIntent) throws -> Void
    typealias StreamLoader = PCMStreamingPlayer.StreamLoader
    typealias RetryDelay = PCMStreamingPlayer.RetryDelay

    private struct ClipAsset {
        let id: String
        let data: Data
    }

    @Published private(set) var playingID: String?
    @Published private(set) var loadingID: String?
    @Published private(set) var lastFinishedID: String?
    @Published var errorMessage: String?

    private var clipPlayer: (any SpeechAudioPlaying)?
    private var clipAsset: ClipAsset?
    private var interruptedClip: (ClipAsset, TimeInterval)?
    private var generation = UUID()
    private var clipLoadTask: Task<Void, Never>?
    private var recordingInterruptionActive = false
    private let makePlayer: PlayerFactory
    private let activateSession: SessionActivator
    private let streamPlayer: PCMStreamingPlayer

    init(
        makePlayer: @escaping PlayerFactory = { try SystemSpeechAudioPlayer(data: $0) },
        makeRenderer: @escaping RendererFactory = { try EngineSpeechRenderer(sampleRate: $0, startingAt: $1) },
        activateSession: @escaping SessionActivator,
        retryDelay: @escaping RetryDelay = { failures in
            try? await Task.sleep(for: .milliseconds(250 * failures))
        }
    ) {
        self.makePlayer = makePlayer
        self.activateSession = activateSession
        streamPlayer = PCMStreamingPlayer(
            makeRenderer: makeRenderer,
            activateSession: { intent in
                try activateSession(intent == .beginPlayback ? .beginPlayback : .rebuildPlayback)
            },
            retryDelay: retryDelay
        )
        streamPlayer.didChange = { [weak self] in self?.syncStreamingState() }
    }

    func toggleReply(turnID: String, destination: KiboDestination, store: AppStore) {
        let id = "reply-\(turnID)"
        if playingID == id || loadingID == id { stop(); return }
        playReply(turnID: turnID, destination: destination, store: store)
    }

    func playReply(turnID: String, destination: KiboDestination, store: AppStore) {
        playReply(id: "reply-\(turnID)") { fromSample, generation in
            try await store.speechStream(
                destination: destination,
                turnID: turnID,
                fromSample: fromSample,
                generation: generation
            )
        }
    }

    func playReply(id: String, load: @escaping StreamLoader) {
        guard playingID != id, loadingID != id else { return }
        stopPlayback()
        streamPlayer.play(id: id, load: load)
    }

    func toggleClip(clipID: String, store: AppStore) {
        let id = "clip-\(clipID)"
        if playingID == id || loadingID == id { stop(); return }
        playClip(id: id) { try await store.clipAudio(clipID: clipID) }
    }

    private func playClip(id: String, load: @escaping @MainActor () async throws -> Data) {
        stopPlayback()
        let generation = UUID()
        self.generation = generation
        loadingID = id
        clipLoadTask = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.clipLoadTask = nil
                self.loadingID = nil
                self.errorMessage = nil
                try self.playLoadedAudio(id: id, data: data)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error, generation: generation)
            }
        }
    }

    /// Capture owns audible hardware immediately, while the reply transport
    /// remains free to fill its append-only cache.
    func pauseForRecording() {
        guard !recordingInterruptionActive else { return }
        recordingInterruptionActive = true
        if streamPlayer.playingID != nil || streamPlayer.loadingID != nil {
            streamPlayer.pauseForCapture()
        } else if let asset = clipAsset, playingID == asset.id {
            interruptedClip = (asset, clipPlayer?.currentTime ?? 0)
            clipPlayer?.stop()
            clipPlayer = nil
        }
    }

    func resumeAfterRecording(rewindBy seconds: TimeInterval = 1) {
        guard recordingInterruptionActive else { return }
        recordingInterruptionActive = false
        if streamPlayer.playingID != nil || streamPlayer.loadingID != nil {
            streamPlayer.resumeAfterCapture(rewindBy: seconds)
            return
        }
        guard let interruptedClip else { return }
        self.interruptedClip = nil
        do {
            try startFreshClip(
                asset: interruptedClip.0,
                at: Self.rewoundTime(interruptedClip.1, by: seconds),
                sessionIntent: .rebuildPlayback
            )
            errorMessage = nil
        } catch {
            fail(error, generation: generation)
        }
    }

    func rebuildAfterRouteChange() {
        streamPlayer.rebuildAfterConfigurationChange()
    }

    func stop() {
        recordingInterruptionActive = false
        stopPlayback()
    }

    private func stopPlayback() {
        generation = UUID()
        clipLoadTask?.cancel()
        clipLoadTask = nil
        streamPlayer.stop()
        clipPlayer?.stop()
        clipPlayer = nil
        clipAsset = nil
        interruptedClip = nil
        playingID = nil
        loadingID = nil
    }

    /// Internal so clip lifecycle can be regression-tested without a request.
    func playLoadedAudio(id: String, data: Data) throws {
        let asset = ClipAsset(id: id, data: data)
        clipAsset = asset
        playingID = id
        if recordingInterruptionActive {
            interruptedClip = (asset, 0)
        } else {
            try startFreshClip(asset: asset, at: 0, sessionIntent: .beginPlayback)
        }
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        clipLoadTask?.cancel()
        clipLoadTask = nil
        streamPlayer.stop()
        clipPlayer?.stop()
        clipPlayer = nil
        clipAsset = nil
        interruptedClip = nil
        playingID = nil
        loadingID = nil
        errorMessage = error.localizedDescription
    }

    private func syncStreamingState() {
        playingID = streamPlayer.playingID
        loadingID = streamPlayer.loadingID
        lastFinishedID = streamPlayer.lastFinishedID
        errorMessage = streamPlayer.errorMessage
    }

    private func startFreshClip(
        asset: ClipAsset,
        at time: TimeInterval,
        sessionIntent: AudioSessionIntent
    ) throws {
        try activateSession(sessionIntent)
        let player = try makePlayer(asset.data)
        player.currentTime = max(0, time)
        player.prepareToPlay()
        player.didFinish = { [weak self, weak player] in
            guard let self, let player, self.clipPlayer === player else { return }
            self.clipPlayer = nil
            self.clipAsset = nil
            self.playingID = nil
        }
        clipPlayer = player
        clipAsset = asset
        playingID = asset.id
        guard player.play() else {
            clipPlayer = nil
            throw PlayerError.couldNotPlay
        }
    }

    static func rewoundTime(_ currentTime: TimeInterval, by seconds: TimeInterval = 1) -> TimeInterval {
        max(0, currentTime - seconds)
    }
}
