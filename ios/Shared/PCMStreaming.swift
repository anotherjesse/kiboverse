import Foundation

/// Append-only decoded speech. All positions are mono sample frames.
struct PCMStreamLedger: Sendable {
    private(set) var samples: [Int16] = []
    private var orphanedByte: UInt8?

    var receivedSample: Int { samples.count }
    var hasPartialSample: Bool { orphanedByte != nil }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var index = data.startIndex
        if let low = orphanedByte {
            samples.append(Int16(bitPattern: UInt16(low) | UInt16(data[index]) << 8))
            orphanedByte = nil
            index = data.index(after: index)
        }
        while index < data.endIndex {
            let next = data.index(after: index)
            guard next < data.endIndex else {
                orphanedByte = data[index]
                break
            }
            samples.append(Int16(bitPattern: UInt16(data[index]) | UInt16(data[next]) << 8))
            index = data.index(after: next)
        }
    }

    /// A resumed response starts at a sample boundary, so an incomplete byte
    /// from the failed response must not be combined with the retried sample.
    mutating func discardPartialSample() {
        orphanedByte = nil
    }

    func chunk(from start: Int, maximumCount: Int) -> [Int16] {
        guard start >= 0, maximumCount > 0, start < samples.count else { return [] }
        let end = min(samples.count, start + maximumCount)
        return Array(samples[start..<end])
    }
}

@MainActor
protocol SpeechRendering: AnyObject {
    var playedSample: Int { get }
    func schedule(
        samples: [Int16],
        startingAt startSample: Int,
        onPlayed: @escaping @MainActor (_ endSample: Int) -> Void
    ) throws
    func play()
    func stop()
}

enum PlaybackSessionIntent: Equatable {
    case beginPlayback
    case rebuildPlayback
}

enum StreamingSpeechError: LocalizedError, Equatable {
    case unsupportedFormat
    case incompleteSample
    case emptySpeech
    case replyTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "The reply used an unsupported audio format."
        case .incompleteSample: "The reply audio ended partway through a sample."
        case .emptySpeech: "The reply contained no audio."
        case .replyTooLong: "The reply audio exceeded this device's safety limit."
        }
    }
}

/// Platform-neutral streaming mechanism. Audio-session and lifecycle policy are
/// supplied by its owner; the mechanism only decodes, retries, and feeds a renderer.
@MainActor
final class PCMStreamingPlayer {
    typealias RendererFactory = @MainActor (_ sampleRate: Int, _ startSample: Int) throws -> any SpeechRendering
    typealias SessionActivator = @MainActor (_ intent: PlaybackSessionIntent) throws -> Void
    typealias StreamLoader = @MainActor (_ fromSample: Int) async throws -> SpeechResponseStream
    typealias RetryDelay = @MainActor (_ failureCount: Int) async -> Void

    private struct StreamAsset {
        let id: String
        var ledger = PCMStreamLedger()
        var sampleRate: Int?
        var scheduledSample = 0
        var confirmedPlayedSample = 0
        var isComplete = false
    }

    private(set) var playingID: String?
    private(set) var loadingID: String?
    private(set) var lastFinishedID: String?
    private(set) var errorMessage: String?
    var didChange: (() -> Void)?

    private var renderer: (any SpeechRendering)?
    private var rendererEpoch = UUID()
    private var streamAsset: StreamAsset?
    private var streamLoader: StreamLoader?
    private var interruptionSample: Int?
    private var pendingPlaybackIntent: PlaybackSessionIntent?
    private var generation = UUID()
    private var transportTask: Task<Void, Never>?
    private var captureOwnsHardware = false
    private let makeRenderer: RendererFactory
    private let activateSession: SessionActivator
    private let maximumReplySamples: Int
    private let retryDelay: RetryDelay

    init(
        makeRenderer: @escaping RendererFactory,
        activateSession: @escaping SessionActivator,
        maximumReplySamples: Int = 24_000 * 60 * 10,
        retryDelay: @escaping RetryDelay = { failures in
            try? await Task.sleep(for: .milliseconds(250 * failures))
        }
    ) {
        self.makeRenderer = makeRenderer
        self.activateSession = activateSession
        self.maximumReplySamples = max(1, maximumReplySamples)
        self.retryDelay = retryDelay
    }

    func play(id: String, load: @escaping StreamLoader) {
        guard playingID != id, loadingID != id else { return }
        stopPlayback(notify: false)
        let generation = UUID()
        self.generation = generation
        streamAsset = StreamAsset(id: id)
        streamLoader = load
        loadingID = id
        lastFinishedID = nil
        errorMessage = nil
        notifyChange()
        transportTask = Task { [weak self] in
            await self?.receiveStream(generation: generation)
        }
    }

    /// Capture takes audible hardware immediately, while transport continues to
    /// fill the bounded append-only cache.
    func pauseForCapture() {
        lastFinishedID = nil
        guard !captureOwnsHardware else { return }
        captureOwnsHardware = true
        if let asset = streamAsset, playingID == asset.id {
            interruptionSample = confirmedPlayhead(for: asset)
            rendererEpoch = UUID()
            renderer?.stop()
            renderer = nil
        }
        notifyChange()
    }

    func resumeAfterCapture(rewindBy seconds: TimeInterval = 1) {
        guard captureOwnsHardware else { return }
        captureOwnsHardware = false
        guard let sample = interruptionSample else {
            pendingPlaybackIntent = .rebuildPlayback
            pumpRenderer(sessionIntent: .rebuildPlayback)
            notifyChange()
            return
        }
        interruptionSample = nil
        pendingPlaybackIntent = nil
        do {
            guard let rate = streamAsset?.sampleRate else { return }
            try startFreshRenderer(
                at: max(0, sample - Int((Double(rate) * seconds).rounded())),
                sessionIntent: .rebuildPlayback
            )
            errorMessage = nil
            notifyChange()
        } catch {
            fail(error, generation: generation)
        }
    }

    func rebuildAfterConfigurationChange() {
        guard !captureOwnsHardware, let asset = streamAsset, playingID == asset.id else { return }
        let sample = confirmedPlayhead(for: asset)
        rendererEpoch = UUID()
        renderer?.stop()
        renderer = nil
        do { try startFreshRenderer(at: sample, sessionIntent: .rebuildPlayback) }
        catch { fail(error, generation: generation) }
    }

    func stop() {
        captureOwnsHardware = false
        lastFinishedID = nil
        stopPlayback(notify: true)
    }

    private func stopPlayback(notify: Bool) {
        generation = UUID()
        rendererEpoch = UUID()
        transportTask?.cancel()
        transportTask = nil
        renderer?.stop()
        renderer = nil
        streamAsset = nil
        streamLoader = nil
        interruptionSample = nil
        pendingPlaybackIntent = nil
        playingID = nil
        loadingID = nil
        if notify { notifyChange() }
    }

    private func receiveStream(generation: UUID) async {
        var failures = 0
        while !Task.isCancelled, self.generation == generation {
            do {
                guard let loader = streamLoader, let asset = streamAsset else { return }
                let response = try await loader(asset.ledger.receivedSample)
                try validate(response: response, generation: generation)
                for try await data in response.chunks {
                    try Task.checkCancellation()
                    guard self.generation == generation, var current = streamAsset else { return }
                    current.ledger.append(data)
                    guard current.ledger.receivedSample <= maximumReplySamples else {
                        throw StreamingSpeechError.replyTooLong
                    }
                    streamAsset = current
                    pumpRenderer(sessionIntent: .beginPlayback)
                    notifyChange()
                }
                guard self.generation == generation, var current = streamAsset else { return }
                guard !current.ledger.hasPartialSample else { throw StreamingSpeechError.incompleteSample }
                guard current.ledger.receivedSample > 0 else { throw StreamingSpeechError.emptySpeech }
                current.isComplete = true
                streamAsset = current
                transportTask = nil
                pumpRenderer(sessionIntent: .beginPlayback)
                finishIfDrained()
                notifyChange()
                return
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation, var current = streamAsset else { return }
                current.ledger.discardPartialSample()
                streamAsset = current
                if let streamError = error as? StreamingSpeechError,
                   streamError != .incompleteSample {
                    fail(error, generation: generation)
                    return
                }
                failures += 1
                if failures >= 4 {
                    fail(error, generation: generation)
                    return
                }
                await retryDelay(failures)
            }
        }
    }

    private func validate(response: SpeechResponseStream, generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation, var asset = streamAsset else {
            throw CancellationError()
        }
        guard response.channels == 1,
              (1...192_000).contains(response.sampleRate),
              response.encoding == .signed16LittleEndian else {
            throw StreamingSpeechError.unsupportedFormat
        }
        if let rate = asset.sampleRate, rate != response.sampleRate {
            throw StreamingSpeechError.unsupportedFormat
        }
        if asset.sampleRate == nil {
            asset.sampleRate = response.sampleRate
            streamAsset = asset
        }
    }

    private func pumpRenderer(sessionIntent: PlaybackSessionIntent) {
        guard !captureOwnsHardware,
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

    private func startFreshRenderer(at startSample: Int, sessionIntent: PlaybackSessionIntent) throws {
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
        let maximumChunk = max(1, rate / 5)
        let played = max(asset.confirmedPlayedSample, renderer.playedSample)
        let schedulingLimit = min(asset.ledger.receivedSample, played + rate)
        while asset.scheduledSample < schedulingLimit {
            let start = asset.scheduledSample
            let samples = asset.ledger.chunk(
                from: start,
                maximumCount: min(maximumChunk, schedulingLimit - start)
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
                    self.notifyChange()
                }
            } catch {
                fail(error, generation: generation)
                return
            }
        }
        streamAsset = asset
        renderer.play()
    }

    private func confirmedPlayhead(for asset: StreamAsset) -> Int {
        min(
            asset.scheduledSample,
            min(asset.ledger.receivedSample, renderer?.playedSample ?? asset.confirmedPlayedSample)
        )
    }

    private func finishIfDrained() {
        guard let asset = streamAsset,
              asset.isComplete,
              asset.confirmedPlayedSample >= asset.ledger.receivedSample else { return }
        lastFinishedID = asset.id
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
        streamAsset = nil
        streamLoader = nil
        interruptionSample = nil
        pendingPlaybackIntent = nil
        playingID = nil
        loadingID = nil
        errorMessage = error.localizedDescription
        notifyChange()
    }

    private func notifyChange() {
        didChange?()
    }
}
