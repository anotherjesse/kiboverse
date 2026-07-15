import Combine
import XCTest
@testable import Kibo_Watch

@MainActor
final class WatchAudioTests: XCTestCase {
    func testLedgerPreservesAlignmentAcrossByteBoundaries() {
        var ledger = PCMStreamLedger()
        ledger.append(Data([0x01]))
        ledger.append(Data([0x00, 0xff, 0xff, 0x02]))
        ledger.append(Data([0x00]))

        XCTAssertEqual(ledger.samples, [1, -1, 2])
        XCTAssertFalse(ledger.hasPartialSample)
    }

    func testStaleLoaderCannotPoisonReplacementStream() async {
        var staleLoader: CheckedContinuation<SpeechResponseStream, Error>?
        var replacementLoader: CheckedContinuation<SpeechResponseStream, Error>?
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }

        player.play(id: "old") { _ in
            try await withCheckedThrowingContinuation { staleLoader = $0 }
        }
        await eventually { staleLoader != nil }

        player.play(id: "new") { _ in
            try await withCheckedThrowingContinuation { replacementLoader = $0 }
        }
        await eventually { replacementLoader != nil }

        // Checked continuations do not cooperate with task cancellation. The
        // old loader deliberately returns first with an incompatible rate.
        staleLoader?.resume(returning: response(rate: 20, chunks: [pcm([8, 9, 10])]))
        await settle()
        replacementLoader?.resume(returning: response(rate: 10, chunks: [pcm([1, 2, 3])]))

        await eventually { renderers.count == 1 }
        XCTAssertEqual(player.playingID, "new")
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(renderers[0].sampleRate, 10)
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2, 3])
    }

    func testFailedOddByteRetriesFromLastCompleteSample() async {
        var offsets: [Int] = []
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }

        player.play(id: "reply") { offset in
            offsets.append(offset)
            if offsets.count == 1 {
                return SpeechResponseStream(
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(Data([1, 0, 0xaa]))
                        continuation.finish(throwing: WatchTestError.failed)
                    }
                )
            }
            return self.response(rate: 10, chunks: [Data([2, 0, 3, 0])])
        }

        await eventually { renderers.count == 1 }
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2, 3])
    }

    func testCleanOddByteRetriesFromLastCompleteSample() async {
        var offsets: [Int] = []
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }

        player.play(id: "reply") { offset in
            offsets.append(offset)
            if offsets.count == 1 {
                return self.response(rate: 10, chunks: [Data([1, 0, 0xaa])])
            }
            return self.response(rate: 10, chunks: [Data([2, 0])])
        }

        await eventually { renderers.count == 1 }
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2])
    }

    func testPrebufferAndCompletionWaitForAudibleDrain() async {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }
        player.play(id: "reply") { _ in
            SpeechResponseStream(
                sampleRate: 10,
                channels: 1,
                chunks: AsyncThrowingStream { continuation = $0 }
            )
        }
        await eventually { continuation != nil }

        continuation?.yield(pcm([1, 2]))
        await settle()
        XCTAssertTrue(renderers.isEmpty, "300 ms at 10 Hz requires three samples")

        continuation?.yield(pcm([3, 4]))
        continuation?.finish()
        await eventually { renderers.count == 1 }
        XCTAssertEqual(player.playingID, "reply")
        XCTAssertNil(player.lastFinishedID)

        renderers[0].completeAll()
        XCTAssertNil(player.playingID)
        XCTAssertEqual(player.lastFinishedID, "reply")
    }

    func testCaptureKeepsTransportAndUsesFreshRendererWithRewind() async {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var renderers: [WatchFakeRenderer] = []
        var intents: [PlaybackSessionIntent] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = WatchFakeRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { intents.append($0) },
            retryDelay: { _ in }
        )
        player.play(id: "reply") { _ in
            SpeechResponseStream(
                sampleRate: 10,
                channels: 1,
                chunks: AsyncThrowingStream { continuation = $0 }
            )
        }
        await eventually { continuation != nil }
        continuation?.yield(pcm(Array(0..<20).map(Int16.init)))
        await eventually { renderers.count == 1 }
        renderers[0].completeAll()
        renderers[0].playedSample = 15

        player.pauseForCapture()
        continuation?.yield(pcm(Array(20..<30).map(Int16.init)))
        continuation?.finish()
        await settle()
        XCTAssertEqual(renderers.count, 1, "Transport must not create hardware during capture")

        player.resumeAfterCapture()
        XCTAssertEqual(renderers.count, 2)
        XCTAssertEqual(renderers[1].startSample, 5)
        XCTAssertEqual(intents, [.beginPlayback, .rebuildPlayback])

        let replacementSchedule = renderers[1].scheduledSamples
        renderers[0].completeAll()
        XCTAssertEqual(renderers[1].scheduledSamples, replacementSchedule)
    }

    func testReleaseBeforePrebufferKeepsRebuildIntent() async {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var renderers: [WatchFakeRenderer] = []
        var intents: [PlaybackSessionIntent] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = WatchFakeRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { intents.append($0) },
            retryDelay: { _ in }
        )
        player.play(id: "reply") { _ in
            SpeechResponseStream(
                sampleRate: 10,
                channels: 1,
                chunks: AsyncThrowingStream { continuation = $0 }
            )
        }
        await eventually { continuation != nil }

        player.pauseForCapture()
        player.resumeAfterCapture()
        continuation?.yield(pcm([1, 2, 3]))
        continuation?.finish()
        await eventually { renderers.count == 1 }

        XCTAssertEqual(intents, [.rebuildPlayback])
    }

    func testWatchMemoryBoundFailsReplyWithoutRenderer() async {
        var renderers: [WatchFakeRenderer] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = WatchFakeRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in },
            maximumReplySamples: 2,
            retryDelay: { _ in }
        )
        player.play(id: "reply") { _ in
            self.response(rate: 10, chunks: [self.pcm([1, 2, 3])])
        }

        await eventually { player.errorMessage != nil }
        XCTAssertTrue(renderers.isEmpty)
        XCTAssertEqual(player.errorMessage, "The reply audio exceeded this device's safety limit.")
    }

    func testCoordinatorCaptureSessionFailureRestoresReply() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        session.failingIntent = .beginCapture
        let capture = WatchFakeCapture(log: log)
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: player,
            observeNotifications: false
        )
        player.play(id: "reply") { _ in self.response(rate: 10, chunks: [self.pcm([1, 2, 3])]) }
        await eventually { renderers.count == 1 }

        coordinator.beginHold()
        await eventually { !coordinator.isHolding }

        XCTAssertEqual(renderers.count, 2)
        XCTAssertTrue(log.events.contains("session.activate:beginCapture"))
        XCTAssertEqual(coordinator.playingID, "reply")
    }

    func testCoordinatorRecorderStartFailureRestoresReply() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        let capture = WatchFakeCapture(log: log)
        capture.startSucceeds = false
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: player,
            observeNotifications: false
        )
        player.play(id: "reply") { _ in self.response(rate: 10, chunks: [self.pcm([1, 2, 3])]) }
        await eventually { renderers.count == 1 }

        coordinator.beginHold()
        await eventually { !coordinator.isHolding }

        XCTAssertEqual(renderers.count, 2)
        XCTAssertTrue(log.events.contains("capture.start"))
        XCTAssertEqual(coordinator.playingID, "reply")
    }

    func testRouteLossAndInterruptionTearDownWithoutStaleResume() async {
        for event in [WatchAudioSystemEvent.outputRouteUnavailable, .interruptionBegan] {
            let log = WatchEventLog()
            let session = WatchFakeSession(log: log)
            let capture = WatchFakeCapture(log: log)
            var renderers: [WatchFakeRenderer] = []
            let player = makePlayer { renderers.append($0) }
            let coordinator = WatchAudioCoordinator(
                recorder: capture,
                session: session,
                player: player,
                observeNotifications: false
            )
            player.play(id: "reply") { _ in
                self.response(rate: 10, chunks: [self.pcm([1, 2, 3, 4])])
            }
            await eventually { renderers.count == 1 }

            coordinator.handleSystemEvent(event)
            renderers[0].completeAll()

            XCTAssertNil(coordinator.playingID)
            XCTAssertNil(coordinator.loadingID)
            XCTAssertEqual(log.events.last, "session.deactivate")
        }
    }

    func testStopForInactivityCannotReactivateSessionLater() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        let capture = WatchFakeCapture(log: log)
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: player,
            observeNotifications: false
        )

        coordinator.beginHold()
        coordinator.stopForInactivity()
        let countAfterStop = log.events.count
        await settle(milliseconds: 100)

        XCTAssertEqual(log.events.count, countAfterStop)
        XCTAssertEqual(log.events.last, "session.deactivate")
        XCTAssertFalse(coordinator.isHolding)
    }

    func testInactivityInvalidatesSuspendedRecorderPreparation() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        let capture = WatchFakeCapture(log: log)
        capture.suspendPrepare = true
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: makePlayer { _ in },
            observeNotifications: false
        )

        coordinator.prepare()
        await eventually { capture.prepareContinuation != nil }
        coordinator.stopForInactivity()
        capture.resumePreparation()
        await settle()

        XCTAssertFalse(capture.hasPreparedAudioObject)
        XCTAssertEqual(log.events.last, "session.deactivate")
    }

    func testMediaResetInvalidatesSuspendedRecorderPreparation() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        let capture = WatchFakeCapture(log: log)
        capture.suspendPrepare = true
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: makePlayer { _ in },
            observeNotifications: false
        )

        coordinator.prepare()
        await eventually { capture.prepareContinuation != nil }
        coordinator.handleSystemEvent(.mediaServicesReset)
        capture.resumePreparation()
        await settle()

        XCTAssertFalse(capture.hasPreparedAudioObject)
        XCTAssertEqual(log.events.last, "session.deactivate")
    }

    private func makePlayer(
        onRenderer: @escaping @MainActor (WatchFakeRenderer) -> Void
    ) -> PCMStreamingPlayer {
        PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = WatchFakeRenderer(sampleRate: rate, startSample: start)
                onRenderer(renderer)
                return renderer
            },
            activateSession: { _ in },
            retryDelay: { _ in }
        )
    }

    private func response(rate: Int, chunks: [Data]) -> SpeechResponseStream {
        SpeechResponseStream(
            sampleRate: rate,
            channels: 1,
            chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    private func pcm(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { sample in
            let value = UInt16(bitPattern: sample)
            return [UInt8(value & 0xff), UInt8(value >> 8)]
        })
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func settle(milliseconds: Int = 30) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

@MainActor
private final class WatchFakeRenderer: SpeechRendering {
    let sampleRate: Int
    let startSample: Int
    var playedSample: Int
    private(set) var scheduledSamples: [Int16] = []
    private var completions: [(Int, @MainActor (Int) -> Void)] = []

    init(sampleRate: Int, startSample: Int) {
        self.sampleRate = sampleRate
        self.startSample = startSample
        playedSample = startSample
    }

    func schedule(
        samples: [Int16],
        startingAt startSample: Int,
        onPlayed: @escaping @MainActor (Int) -> Void
    ) {
        scheduledSamples.append(contentsOf: samples)
        completions.append((startSample + samples.count, onPlayed))
    }

    func play() {}
    func stop() {}

    func completeAll() {
        let callbacks = completions
        completions = []
        for (end, completion) in callbacks {
            playedSample = max(playedSample, end)
            completion(end)
        }
    }
}

@MainActor
private final class WatchEventLog {
    var events: [String] = []
}

@MainActor
private final class WatchFakeSession: WatchAudioSessionControlling {
    private let log: WatchEventLog
    var failingIntent: WatchAudioSessionIntent?

    init(log: WatchEventLog) { self.log = log }

    func activate(for intent: WatchAudioSessionIntent) throws {
        log.events.append("session.activate:\(intent)")
        if failingIntent == intent { throw WatchTestError.failed }
    }

    func deactivate() { log.events.append("session.deactivate") }
}

@MainActor
private final class WatchFakeCapture: WatchAudioCapturing {
    let objectWillChange = ObservableObjectPublisher()
    private let log: WatchEventLog
    var isRecording = false
    var isStarting = false
    var level: CGFloat = 0
    var errorMessage: String?
    var startSucceeds = true
    var suspendPrepare = false
    private(set) var hasPreparedAudioObject = false
    private var preparationEpoch = 0
    var prepareContinuation: CheckedContinuation<Void, Never>?

    init(log: WatchEventLog) { self.log = log }

    func prepare() async {
        let epoch = preparationEpoch
        log.events.append("capture.prepare")
        if suspendPrepare {
            await withCheckedContinuation { prepareContinuation = $0 }
        }
        guard !Task.isCancelled, preparationEpoch == epoch else { return }
        hasPreparedAudioObject = true
        log.events.append("capture.prepare.install")
    }

    func resumePreparation() {
        let continuation = prepareContinuation
        prepareContinuation = nil
        continuation?.resume()
    }
    func start(holdID: UUID) async -> Bool {
        log.events.append("capture.start")
        isRecording = startSucceeds
        return startSucceeds
    }
    func stop(holdID: UUID) -> WatchLocalRecording? {
        log.events.append("capture.stop")
        isRecording = false
        return nil
    }
    func cancel(holdID: UUID?) {
        log.events.append("capture.cancel")
        isRecording = false
    }
    func resetAudioObjects() {
        log.events.append("capture.reset")
        preparationEpoch += 1
        hasPreparedAudioObject = false
        isRecording = false
    }
}

private enum WatchTestError: Error {
    case failed
}
