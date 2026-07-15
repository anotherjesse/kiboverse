@preconcurrency import AVFoundation

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

@MainActor
final class EngineSpeechRenderer: SpeechRendering {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let baseSample: Int
    private var lastPlayedSample: Int
    private var lastScheduledSample: Int
    private var stopped = false

    init(sampleRate: Int, startingAt startSample: Int) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw PlayerError.unsupportedFormat
        }
        self.format = format
        baseSample = startSample
        lastPlayedSample = startSample
        lastScheduledSample = startSample
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    var playedSample: Int {
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime),
              playerTime.isSampleTimeValid else {
            return lastPlayedSample
        }
        return min(
            lastScheduledSample,
            max(lastPlayedSample, baseSample + Int(playerTime.sampleTime))
        )
    }

    func schedule(
        samples: [Int16],
        startingAt startSample: Int,
        onPlayed: @escaping @MainActor (_ endSample: Int) -> Void
    ) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData?.pointee else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        let endSample = startSample + samples.count
        lastScheduledSample = max(lastScheduledSample, endSample)
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] callbackType in
            // AVAudioPlayerNode also invokes scheduled callbacks when stop()
            // clears its queue. Only actual speaker drain advances playedSample.
            guard callbackType == .dataPlayedBack else { return }
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.lastPlayedSample = max(self.lastPlayedSample, endSample)
                onPlayed(endSample)
            }
        }
    }

    func play() {
        if !player.isPlaying { player.play() }
    }

    func stop() {
        stopped = true
        player.stop()
        engine.stop()
    }

    deinit {
        stopped = true
        player.stop()
        engine.stop()
    }
}

enum PlayerError: LocalizedError {
    case couldNotPlay
    case unsupportedFormat
    case incompleteSample
    case emptySpeech
    case replyTooLong

    var errorDescription: String? {
        switch self {
        case .couldNotPlay: "The reply audio could not be played."
        case .unsupportedFormat: "The reply used an unsupported audio format."
        case .incompleteSample: "The reply audio ended partway through a sample."
        case .emptySpeech: "The reply contained no audio."
        case .replyTooLong: "The reply audio exceeded the ten-minute safety limit."
        }
    }
}
