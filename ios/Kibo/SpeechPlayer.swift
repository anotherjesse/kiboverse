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
    private static let maximumReplySamples = 24_000 * 60 * 10
    typealias PlayerFactory = @MainActor (Data) throws -> any SpeechAudioPlaying
    typealias RendererFactory = @MainActor (_ sampleRate: Int, _ startSample: Int) throws -> any SpeechRendering
    typealias SessionActivator = @MainActor (_ intent: AudioSessionIntent) throws -> Void
    typealias StreamLoader = @MainActor (_ fromSample: Int) async throws -> SpeechResponseStream

    private struct ClipAsset {
        let id: String
        let data: Data
    }

    private struct StreamAsset {
        let id: String
        var ledger = PCMStreamLedger()
        var sampleRate: Int?
        var scheduledSample = 0
        var confirmedPlayedSample = 0
        var isComplete = false
    }

    private enum InterruptionSnapshot {
        case clip(ClipAsset, TimeInterval)
        case stream(Int)
    }

    @Published private(set) var playingID: String?
    @Published private(set) var loadingID: String?
    @Published var errorMessage: String?

    private var clipPlayer: (any SpeechAudioPlaying)?
    private var clipAsset: ClipAsset?
    private var renderer: (any SpeechRendering)?
    private var rendererEpoch = UUID()
    private var streamAsset: StreamAsset?
    private var streamLoader: StreamLoader?
    private var interruptionSnapshot: InterruptionSnapshot?
    private var pendingPlaybackIntent: AudioSessionIntent?
    private var generation = UUID()
    private var transportTask: Task<Void, Never>?
    private var recordingInterruptionActive = false
    private let makePlayer: PlayerFactory
    private let makeRenderer: RendererFactory
    private let activateSession: SessionActivator

    init(
        makePlayer: @escaping PlayerFactory = { try SystemSpeechAudioPlayer(data: $0) },
        makeRenderer: @escaping RendererFactory = { try EngineSpeechRenderer(sampleRate: $0, startingAt: $1) },
        activateSession: @escaping SessionActivator
    ) {
        self.makePlayer = makePlayer
        self.makeRenderer = makeRenderer
        self.activateSession = activateSession
    }

    func toggleReply(turnID: String, store: AppStore) {
        let id = "reply-\(turnID)"
        if playingID == id || loadingID == id { stop(); return }
        playReply(turnID: turnID, store: store)
    }

    func playReply(turnID: String, store: AppStore) {
        playReply(id: "reply-\(turnID)") { fromSample in
            try await store.speechStream(turnID: turnID, fromSample: fromSample)
        }
    }

    func playReply(id: String, load: @escaping StreamLoader) {
        guard playingID != id, loadingID != id else { return }
        stopPlayback()
        let generation = UUID()
        self.generation = generation
        streamAsset = StreamAsset(id: id)
        streamLoader = load
        loadingID = id
        errorMessage = nil
        transportTask = Task { [weak self] in
            await self?.receiveStream(generation: generation)
        }
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
        transportTask = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.transportTask = nil
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
        if let asset = streamAsset, playingID == asset.id {
            let sample = min(
                asset.scheduledSample,
                min(asset.ledger.receivedSample, renderer?.playedSample ?? asset.confirmedPlayedSample)
            )
            interruptionSnapshot = .stream(sample)
            rendererEpoch = UUID()
            renderer?.stop()
            renderer = nil
        } else if let asset = clipAsset, playingID == asset.id {
            interruptionSnapshot = .clip(asset, clipPlayer?.currentTime ?? 0)
            clipPlayer?.stop()
            clipPlayer = nil
        }
    }

    func resumeAfterRecording(rewindBy seconds: TimeInterval = 1) {
        guard recordingInterruptionActive else { return }
        recordingInterruptionActive = false
        guard let snapshot = interruptionSnapshot else {
            pendingPlaybackIntent = .rebuildPlayback
            pumpRenderer(sessionIntent: .rebuildPlayback)
            return
        }
        interruptionSnapshot = nil
        pendingPlaybackIntent = nil
        do {
            switch snapshot {
            case let .clip(asset, time):
                try startFreshClip(
                    asset: asset,
                    at: Self.rewoundTime(time, by: seconds),
                    sessionIntent: .rebuildPlayback
                )
            case let .stream(sample):
                guard let rate = streamAsset?.sampleRate else { return }
                try startFreshRenderer(
                    at: max(0, sample - Int((Double(rate) * seconds).rounded())),
                    sessionIntent: .rebuildPlayback
                )
            }
            errorMessage = nil
        } catch {
            fail(error, generation: generation)
        }
    }

    func rebuildAfterRouteChange() {
        guard !recordingInterruptionActive, let asset = streamAsset, playingID == asset.id else { return }
        let sample = min(
            asset.scheduledSample,
            min(asset.ledger.receivedSample, renderer?.playedSample ?? asset.confirmedPlayedSample)
        )
        rendererEpoch = UUID()
        renderer?.stop()
        renderer = nil
        do { try startFreshRenderer(at: sample, sessionIntent: .rebuildPlayback) }
        catch { fail(error, generation: generation) }
    }

    func stop() {
        recordingInterruptionActive = false
        stopPlayback()
    }

    private func stopPlayback() {
        generation = UUID()
        rendererEpoch = UUID()
        transportTask?.cancel()
        transportTask = nil
        renderer?.stop()
        renderer = nil
        clipPlayer?.stop()
        clipPlayer = nil
        clipAsset = nil
        streamAsset = nil
        streamLoader = nil
        interruptionSnapshot = nil
        pendingPlaybackIntent = nil
        playingID = nil
        loadingID = nil
    }

    /// Internal so clip lifecycle can be regression-tested without a request.
    func playLoadedAudio(id: String, data: Data) throws {
        let asset = ClipAsset(id: id, data: data)
        clipAsset = asset
        playingID = id
        if recordingInterruptionActive {
            interruptionSnapshot = .clip(asset, 0)
        } else {
            try startFreshClip(asset: asset, at: 0, sessionIntent: .beginPlayback)
        }
    }

    private func receiveStream(generation: UUID) async {
        var failures = 0
        while !Task.isCancelled, self.generation == generation {
            do {
                guard let loader = streamLoader, let asset = streamAsset else { return }
                let response = try await loader(asset.ledger.receivedSample)
                try validate(response: response)
                for try await data in response.chunks {
                    try Task.checkCancellation()
                    guard self.generation == generation, var current = streamAsset else { return }
                    current.ledger.append(data)
                    guard current.ledger.receivedSample <= Self.maximumReplySamples else {
                        throw PlayerError.replyTooLong
                    }
                    streamAsset = current
                    pumpRenderer(sessionIntent: .beginPlayback)
                }
                guard self.generation == generation, var current = streamAsset else { return }
                guard !current.ledger.hasPartialSample else { throw PlayerError.incompleteSample }
                guard current.ledger.receivedSample > 0 else { throw PlayerError.emptySpeech }
                current.isComplete = true
                streamAsset = current
                transportTask = nil
                pumpRenderer(sessionIntent: .beginPlayback)
                finishIfDrained()
                return
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation, var current = streamAsset else { return }
                current.ledger.discardPartialSample()
                streamAsset = current
                if let playerError = error as? PlayerError {
                    switch playerError {
                    case .incompleteSample:
                        break
                    default:
                        fail(error, generation: generation)
                        return
                    }
                }
                failures += 1
                if failures >= 4 {
                    fail(error, generation: generation)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250 * failures))
            }
        }
    }

    private func validate(response: SpeechResponseStream) throws {
        guard response.channels == 1,
              (1...192_000).contains(response.sampleRate),
              response.encoding == .signed16LittleEndian else {
            throw PlayerError.unsupportedFormat
        }
        if let rate = streamAsset?.sampleRate, rate != response.sampleRate {
            throw PlayerError.unsupportedFormat
        }
        if streamAsset?.sampleRate == nil {
            streamAsset?.sampleRate = response.sampleRate
        }
    }

    private func pumpRenderer(sessionIntent: AudioSessionIntent) {
        guard !recordingInterruptionActive,
              let asset = streamAsset,
              let rate = asset.sampleRate else { return }
        if renderer != nil {
            scheduleAvailable()
            return
        }
        let prebuffer = max(1, rate * 3 / 10)
        guard asset.ledger.receivedSample >= prebuffer || asset.isComplete else { return }
        do {
            try startFreshRenderer(
                at: asset.confirmedPlayedSample,
                sessionIntent: pendingPlaybackIntent ?? sessionIntent
            )
            pendingPlaybackIntent = nil
        } catch {
            fail(error, generation: generation)
        }
    }

    private func startFreshRenderer(at startSample: Int, sessionIntent: AudioSessionIntent) throws {
        guard var asset = streamAsset, let rate = asset.sampleRate else { return }
        try activateSession(sessionIntent)
        rendererEpoch = UUID()
        renderer?.stop()
        let start = min(max(0, startSample), asset.ledger.receivedSample)
        let renderer = try makeRenderer(rate, start)
        self.renderer = renderer
        rendererEpoch = UUID()
        asset.scheduledSample = start
        asset.confirmedPlayedSample = start
        streamAsset = asset
        playingID = asset.id
        loadingID = nil
        scheduleAvailable()
        renderer.play()
    }

    private func scheduleAvailable() {
        guard let renderer, var asset = streamAsset, let rate = asset.sampleRate else { return }
        let generation = generation
        let rendererEpoch = rendererEpoch
        let maximum = max(1, rate / 5)
        let played = max(asset.confirmedPlayedSample, renderer.playedSample)
        let schedulingLimit = min(asset.ledger.receivedSample, played + rate)
        while asset.scheduledSample < schedulingLimit {
            let start = asset.scheduledSample
            let samples = asset.ledger.chunk(
                from: start,
                maximumCount: min(maximum, schedulingLimit - start)
            )
            guard !samples.isEmpty else { break }
            asset.scheduledSample += samples.count
            do {
                try renderer.schedule(samples: samples, startingAt: start) { [weak self] endSample in
                    guard let self,
                          self.generation == generation,
                          self.rendererEpoch == rendererEpoch,
                          var current = self.streamAsset else { return }
                    current.confirmedPlayedSample = max(current.confirmedPlayedSample, endSample)
                    self.streamAsset = current
                    self.scheduleAvailable()
                    self.finishIfDrained()
                }
            } catch {
                fail(error, generation: generation)
                return
            }
        }
        streamAsset = asset
        renderer.play()
    }

    private func finishIfDrained() {
        guard let asset = streamAsset,
              asset.isComplete,
              asset.confirmedPlayedSample >= asset.ledger.receivedSample else { return }
        renderer = nil
        rendererEpoch = UUID()
        streamAsset = nil
        streamLoader = nil
        playingID = nil
        loadingID = nil
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        transportTask?.cancel()
        transportTask = nil
        rendererEpoch = UUID()
        renderer?.stop()
        renderer = nil
        clipPlayer?.stop()
        clipPlayer = nil
        clipAsset = nil
        streamAsset = nil
        streamLoader = nil
        interruptionSnapshot = nil
        pendingPlaybackIntent = nil
        playingID = nil
        loadingID = nil
        errorMessage = error.localizedDescription
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
