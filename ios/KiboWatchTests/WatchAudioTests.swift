import Combine
import XCTest
@testable import Kibo_Watch

@MainActor
final class WatchAudioTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        WatchStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testOlderSameSelectionRefreshCannotReplaceNewerEventsOrAdvanceRevision() async {
        let savedServerURL = UserDefaults.standard.string(forKey: "watchServerURL")
        UserDefaults.standard.set("https://refresh-order.test/", forKey: "watchServerURL")
        defer {
            if let savedServerURL {
                UserDefaults.standard.set(savedServerURL, forKey: "watchServerURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "watchServerURL")
            }
        }

        let firstStarted = expectation(description: "first refresh started")
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let lock = NSLock()
        var requestCount = 0
        WatchStubURLProtocol.handler = { request in
            let requestNumber = lock.withLock {
                requestCount += 1
                return requestCount
            }
            let body: Data
            if requestNumber == 1 {
                firstStarted.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 2)
                body = #"{"events":[{"seq":1,"kind":"reply_error","turn":"t1","terminal":true,"error":"stale"}],"latest_seq":1}"#.data(using: .utf8)!
            } else {
                body = #"{"events":[{"seq":2,"kind":"speech_started","turn":"t1","attempt":2}],"latest_seq":2}"#.data(using: .utf8)!
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        let store = WatchStore(session: session)
        store.selectedProjectID = "p1"
        store.selectedConversationID = "c1"
        let first = Task { await store.refreshEvents() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await store.refreshEvents() }
        let secondAccepted = await second.value
        XCTAssertTrue(secondAccepted)
        releaseFirst.signal()
        let firstAccepted = await first.value
        XCTAssertFalse(firstAccepted)

        XCTAssertEqual(store.events.map(\.seq), [2])
        XCTAssertEqual(store.eventRevision, 1)
    }

    func testReplyReconnectKeepsItsImmutableDestinationAfterSelectionChanges() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "watchServerURL")
        UserDefaults.standard.set("https://watch-reply-owner.test/", forKey: "watchServerURL")
        defer {
            if let savedServerURL {
                UserDefaults.standard.set(savedServerURL, forKey: "watchServerURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "watchServerURL")
            }
        }

        let lock = NSLock()
        var requestPaths: [String] = []
        WatchStubURLProtocol.handler = { request in
            lock.withLock { requestPaths.append(request.url!.path) }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil
                )!,
                Data()
            )
        }

        let firstRetry = expectation(description: "first Watch stream load failed")
        var mayRetry = false
        var retryFailures: [Int] = []
        let store = WatchStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "old-conversation"
        let destination = try XCTUnwrap(store.requestDestination)
        let player = PCMStreamingPlayer(
            makeRenderer: { WatchFakeRenderer(sampleRate: $0, startSample: $1) },
            activateSession: { _ in },
            retryDelay: { failures in
                retryFailures.append(failures)
                if failures == 1 {
                    firstRetry.fulfill()
                    while !mayRetry { await Task.yield() }
                }
            }
        )
        let log = WatchEventLog()
        let coordinator = WatchAudioCoordinator(
            recorder: WatchFakeCapture(log: log),
            session: WatchFakeSession(log: log),
            player: player,
            observeNotifications: false
        )

        coordinator.playReply(
            turnID: "shared-turn", destination: destination, store: store
        )
        await fulfillment(of: [firstRetry], timeout: 1)
        XCTAssertEqual(coordinator.loadingID, "reply-shared-turn")
        store.selectedConversationID = "new-conversation"
        mayRetry = true

        await eventually { coordinator.loadingID == nil }
        XCTAssertEqual(retryFailures, [1])
        XCTAssertEqual(lock.withLock { requestPaths }, [
            "/v1/projects/project/conversations/old-conversation/turns/shared-turn/speech",
        ])
        XCTAssertNil(coordinator.playbackErrorMessage)
    }

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

        player.play(id: "old") { _, _ in
            try await withCheckedThrowingContinuation { staleLoader = $0 }
        }
        await eventually { staleLoader != nil }

        player.play(id: "new") { _, _ in
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

        player.play(id: "reply") { offset, _ in
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

    func testNewSpeechGenerationDiscardsEarlierAttemptAndRestartsAtZero() async {
        var offsets: [Int] = []
        var expectedGenerations: [String?] = []
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }

        player.play(id: "reply") { offset, expectedGeneration in
            offsets.append(offset)
            expectedGenerations.append(expectedGeneration)
            switch offsets.count {
            case 1:
                return SpeechResponseStream(
                    generation: "attempt-1",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcm([1, 2, 3, 4]))
                        continuation.finish(throwing: WatchTestError.failed)
                    }
                )
            case 2:
                return SpeechResponseStream(
                    generation: "attempt-2",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcm([99]))
                        continuation.finish()
                    }
                )
            default:
                return SpeechResponseStream(
                    generation: "attempt-2",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcm([10, 11, 12, 13]))
                        continuation.finish()
                    }
                )
            }
        }

        await eventually { renderers.count == 2 }
        XCTAssertEqual(offsets, [0, 4, 0])
        XCTAssertEqual(expectedGenerations, [nil, "attempt-1", "attempt-2"])
        XCTAssertTrue(renderers[0].wasStopped)
        XCTAssertEqual(renderers[1].scheduledSamples, [10, 11, 12, 13])
    }

    func testCleanOddByteRetriesFromLastCompleteSample() async {
        var offsets: [Int] = []
        var renderers: [WatchFakeRenderer] = []
        let player = makePlayer { renderers.append($0) }

        player.play(id: "reply") { offset, _ in
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
        player.play(id: "reply") { _, _ in
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
        player.play(id: "reply") { _, _ in
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
        player.play(id: "reply") { _, _ in
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
        player.play(id: "reply") { _, _ in
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
        player.play(id: "reply") { _, _ in self.response(rate: 10, chunks: [self.pcm([1, 2, 3])]) }
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
        player.play(id: "reply") { _, _ in self.response(rate: 10, chunks: [self.pcm([1, 2, 3])]) }
        await eventually { renderers.count == 1 }

        coordinator.beginHold()
        await eventually { !coordinator.isHolding }

        XCTAssertEqual(renderers.count, 2)
        XCTAssertTrue(log.events.contains("capture.start"))
        XCTAssertEqual(coordinator.playingID, "reply")
    }

    func testRouteLossAndInterruptionTearDownWithoutStaleResume() async {
        for event in [AudioSystemEvent.outputRouteUnavailable, .interruptionBegan] {
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
            player.play(id: "reply") { _, _ in
                self.response(rate: 10, chunks: [self.pcm([1, 2, 3, 4])])
            }
            await eventually { renderers.count == 1 }

            coordinator.handleSystemEvent(event)
            renderers[0].completeAll()

            XCTAssertTrue(coordinator.automaticPlaybackSuspended)
            XCTAssertNil(coordinator.playingID)
            XCTAssertNil(coordinator.loadingID)
            XCTAssertEqual(log.events.last, "session.deactivate")
        }
    }

    func testSystemEventsPreserveActiveCaptureForRecovery() async {
        for event in [AudioSystemEvent.outputRouteUnavailable, .interruptionBegan] {
            let log = WatchEventLog()
            var inventoryRefreshes = 0
            let session = WatchFakeSession(log: log)
            let capture = WatchFakeCapture(log: log)
            let coordinator = WatchAudioCoordinator(
                recorder: capture,
                session: session,
                player: makePlayer { _ in },
                observeNotifications: false,
                recordingInventoryDidChange: { inventoryRefreshes += 1 }
            )
            coordinator.beginHold()
            await eventually { capture.isRecording }
            log.events.removeAll()

            coordinator.handleSystemEvent(event)

            XCTAssertTrue(log.events.contains("capture.preserve"))
            XCTAssertFalse(log.events.contains("capture.cancel"))
            XCTAssertEqual(inventoryRefreshes, 1)
            XCTAssertFalse(coordinator.isHolding)
            XCTAssertFalse(capture.isRecording)
        }
    }

    func testForegroundPreparationDoesNotClearSystemPlaybackSuspension() async {
        let log = WatchEventLog()
        let session = WatchFakeSession(log: log)
        let capture = WatchFakeCapture(log: log)
        let coordinator = WatchAudioCoordinator(
            recorder: capture,
            session: session,
            player: makePlayer { _ in },
            observeNotifications: false
        )

        coordinator.handleSystemEvent(.outputRouteUnavailable)
        coordinator.stopForInactivity()
        coordinator.prepare()
        await eventually { capture.hasPreparedAudioObject }

        XCTAssertTrue(coordinator.automaticPlaybackSuspended)
        coordinator.resumeAutomaticPlayback()
        XCTAssertFalse(coordinator.automaticPlaybackSuspended)
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
    private(set) var wasStopped = false
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
    func stop() { wasStopped = true }

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
private final class WatchFakeSession: AudioSessionControlling {
    private let log: WatchEventLog
    var failingIntent: AudioSessionIntent?

    init(log: WatchEventLog) { self.log = log }

    func activate(for intent: AudioSessionIntent) throws {
        log.events.append("session.activate:\(intent)")
        if failingIntent == intent { throw WatchTestError.failed }
    }

    func deactivate() { log.events.append("session.deactivate") }
}

@MainActor
private final class WatchFakeCapture: AudioCapturing {
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
    func stop(holdID: UUID) -> LocalRecording? {
        log.events.append("capture.stop")
        isRecording = false
        return nil
    }
    func cancel(holdID: UUID?) {
        log.events.append("capture.cancel")
        isRecording = false
    }
    func preserveForRecovery(holdID: UUID?) {
        log.events.append("capture.preserve")
        isRecording = false
    }
    func resetAudioObjects() {
        log.events.append("capture.reset")
        preparationEpoch += 1
        hasPreparedAudioObject = false
        isRecording = false
    }
}

private final class WatchStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum WatchTestError: Error {
    case failed
}
