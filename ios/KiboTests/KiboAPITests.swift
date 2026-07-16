@preconcurrency import AVFoundation
import Combine
import XCTest
@testable import Kibo

@MainActor
final class KiboAPITests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testListsProjectsAndUsesVersionedPath() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/projects")
            let body = #"{"projects":[{"id":"kibo","name":"Kibo","created_at":1}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let api = try KiboAPI(serverURL: "http://example.test", session: session)
        let projects = try await api.projects()
        XCTAssertEqual(projects.first?.name, "Kibo")
    }

    func testBasePathAndTrailingSlashArePreserved() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/kibo/v1/projects")
            let body = #"{"projects":[]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let api = try KiboAPI(serverURL: "https://example.test/gateway/kibo/", session: session)
        let projects = try await api.projects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testClipUploadUsesServerContractHeaders() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/projects/p/conversations/c/clips/clip-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Duration-Ms"), "875")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Peak-Pct"), "42")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Recorded-At"), "1234")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-Sha256")?.count, 64)
            let body = #"{"clip_id":"clip-1","created":true}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 44).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)
        try await api.uploadClip(
            fileURL: url, projectID: "p", conversationID: "c", clipID: "clip-1",
            durationMs: 875, peakPct: 42, recordedAt: 1234
        )
    }

    func testSpeechStreamUsesSampleResumeOffsetAndDeliversPCMIncrementally() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/projects/p/conversations/c/turns/t/speech"
            )
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "from_sample" })?.value,
                "17"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/vnd.kibo.pcm; format=s16le"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/vnd.kibo.pcm; format=s16le",
                    "X-Audio-Sample-Rate": "24000",
                    "X-Audio-Channels": "1",
                ]
            )!
            return (response, Data([1, 0, 2, 0]))
        }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)
        let response = try await api.speechStream(
            projectID: "p",
            conversationID: "c",
            turnID: "t",
            fromSample: 17
        )
        var body = Data()
        for try await chunk in response.chunks { body.append(chunk) }
        XCTAssertEqual(response.sampleRate, 24_000)
        XCTAssertEqual(response.channels, 1)
        XCTAssertEqual(body, Data([1, 0, 2, 0]))
    }

    func testTimelineBuildsPersonAndReplyCards() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript","clip":"c1","text":"Hello"},{"seq":3,"kind":"turn","id":"t1","clips":["c1"]},{"seq":4,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.timeline().map(\.body), ["Hello", "Hi"])
        XCTAssertTrue(events.timeline().last?.canPlay == true)
    }

    func testTimelineSplitsEachRecordingIntoItsOwnCard() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1","ms":1500},{"seq":2,"kind":"clip","id":"c2","ms":900},{"seq":3,"kind":"transcript","clip":"c1","text":"First"},{"seq":4,"kind":"transcript","clip":"c2","text":"Second"},{"seq":5,"kind":"turn","id":"t1","clips":["c1","c2"]},{"seq":6,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        let cards = events.timeline()
        XCTAssertEqual(cards.map(\.body), ["First", "Second", "Hi"])
        XCTAssertEqual(cards.compactMap(\.clipID), ["c1", "c2"])
        XCTAssertEqual(cards.first?.durationMs, 1500)
        XCTAssertTrue(cards.allSatisfy { $0.role == .kibo || $0.canPlay })
    }

    func testTimelineUsesLatestDuplicateEventInsteadOfCrashing() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_error","clip":"c1","error":"first"},{"seq":3,"kind":"transcript_error","clip":"c1","error":"latest"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.timeline().single?.body, "latest")
    }

    func testPendingTurnEndsWhenReplyArrives() throws {
        let pendingData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]}]"#.data(using: .utf8)!
        let pending = try JSONDecoder().decode([KiboEvent].self, from: pendingData)
        XCTAssertEqual(pending.pendingTurnIDs, ["t1"])

        let finishedData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Done"}]"#.data(using: .utf8)!
        let finished = try JSONDecoder().decode([KiboEvent].self, from: finishedData)
        XCTAssertTrue(finished.pendingTurnIDs.isEmpty)
    }

    func testPCMStreamLedgerCarriesSamplesAcrossArbitraryByteBoundaries() {
        var ledger = PCMStreamLedger()
        ledger.append(Data([0x01]))
        XCTAssertEqual(ledger.receivedSample, 0)
        XCTAssertTrue(ledger.hasPartialSample)

        ledger.append(Data([0x02, 0xff, 0x7f, 0x00]))
        XCTAssertEqual(ledger.samples, [513, 32_767])
        XCTAssertTrue(ledger.hasPartialSample)

        ledger.append(Data([0x80]))
        XCTAssertEqual(ledger.samples, [513, 32_767, -32_768])
        XCTAssertFalse(ledger.hasPartialSample)
    }

    func testPCMStreamLedgerDropsFailedPartialByteBeforeResume() {
        var ledger = PCMStreamLedger()
        ledger.append(Data([0x01, 0x02, 0xaa]))
        XCTAssertEqual(ledger.receivedSample, 1)
        ledger.discardPartialSample()
        ledger.append(Data([0x03, 0x04]))
        XCTAssertEqual(ledger.samples, [513, 1_027])
    }

    func testPCMStreamLedgerChunksUseSampleOffsets() {
        var ledger = PCMStreamLedger()
        ledger.append(Data([0, 0, 1, 0, 2, 0, 3, 0]))
        XCTAssertEqual(ledger.chunk(from: 1, maximumCount: 2), [1, 2])
        XCTAssertEqual(ledger.chunk(from: 4, maximumCount: 2), [])
    }

    func testReplyResumeRewindsOneSecondWithoutGoingNegative() {
        XCTAssertEqual(SpeechPlayer.rewoundTime(8.4), 7.4, accuracy: 0.001)
        XCTAssertEqual(SpeechPlayer.rewoundTime(0.4), 0, accuracy: 0.001)
    }

    func testEveryRecordingInterruptionCreatesFreshPlaybackEngine() throws {
        var players: [FakeSpeechAudioPlayer] = []
        var sessionIntents: [AudioSessionIntent] = []
        let speech = SpeechPlayer(
            makePlayer: { _ in
                let player = FakeSpeechAudioPlayer()
                players.append(player)
                return player
            },
            activateSession: { sessionIntents.append($0) }
        )

        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        players[0].currentTime = 8.4
        speech.pauseForRecording()
        XCTAssertTrue(players[0].wasStopped)
        speech.resumeAfterRecording()

        XCTAssertEqual(players.count, 2)
        XCTAssertEqual(players[1].currentTime, 7.4, accuracy: 0.001)
        players[0].didFinish?()
        XCTAssertEqual(speech.playingID, "reply", "A stale completion must not stop the replacement player")
        players[1].currentTime = 12.25
        speech.pauseForRecording()
        speech.resumeAfterRecording()

        XCTAssertEqual(players.count, 3)
        XCTAssertEqual(players[2].currentTime, 11.25, accuracy: 0.001)
        XCTAssertEqual(sessionIntents, [.beginPlayback, .rebuildPlayback, .rebuildPlayback])
        XCTAssertEqual(players.map(\.playCount), [1, 1, 1])
    }

    func testReplyLoadedDuringHoldWaitsForRelease() throws {
        var players: [FakeSpeechAudioPlayer] = []
        let speech = SpeechPlayer(
            makePlayer: { _ in
                let player = FakeSpeechAudioPlayer()
                players.append(player)
                return player
            },
            activateSession: { _ in }
        )

        speech.pauseForRecording()
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        XCTAssertTrue(players.isEmpty)

        speech.resumeAfterRecording()
        XCTAssertEqual(players.count, 1)
        XCTAssertEqual(players[0].currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(players[0].playCount, 1)
    }

    func testAudioCoordinatorOwnsCapturePlaybackOrdering() async throws {
        let log = AudioEventLog()
        let session = FakeAudioSession(log: log)
        let capture = FakeAudioCapture(log: log)
        let speech = SpeechPlayer(
            makePlayer: { _ in FakeSpeechAudioPlayer(log: log) },
            activateSession: { try session.activate(for: $0) }
        )
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        log.events.removeAll()
        let coordinator = AudioCoordinator(
            recorder: capture,
            session: session,
            player: speech,
            observeNotifications: false
        )

        coordinator.beginHold()
        await eventually { capture.isRecording }
        _ = coordinator.endHold()

        XCTAssertEqual(Array(log.events.prefix(6)), [
            "clip.stop",
            "session.activate:beginCapture",
            "capture.start",
            "capture.stop",
            "session.activate:rebuildPlayback",
            "clip.play",
        ])
    }

    func testAudioCoordinatorClearsHoldWhenCaptureSessionFails() async throws {
        let log = AudioEventLog()
        let session = FakeAudioSession(log: log)
        session.failingIntent = .beginCapture
        let capture = FakeAudioCapture(log: log)
        let speech = SpeechPlayer(
            makePlayer: { _ in FakeSpeechAudioPlayer(log: log) },
            activateSession: { try session.activate(for: $0) }
        )
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        log.events.removeAll()
        let coordinator = AudioCoordinator(
            recorder: capture,
            session: session,
            player: speech,
            observeNotifications: false
        )

        coordinator.beginHold()
        await eventually { !coordinator.isHolding }

        XCTAssertFalse(capture.isRecording)
        XCTAssertFalse(log.events.contains("capture.start"))
        XCTAssertEqual(Array(log.events.prefix(4)), [
            "clip.stop",
            "session.activate:beginCapture",
            "session.activate:rebuildPlayback",
            "clip.play",
        ])
    }

    func testSystemRouteLossCancelsCaptureWithoutResumingPlayback() async throws {
        let log = AudioEventLog()
        let session = FakeAudioSession(log: log)
        let capture = FakeAudioCapture(log: log)
        let speech = SpeechPlayer(
            makePlayer: { _ in FakeSpeechAudioPlayer(log: log) },
            activateSession: { try session.activate(for: $0) }
        )
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        let coordinator = AudioCoordinator(
            recorder: capture,
            session: session,
            player: speech,
            observeNotifications: false
        )
        coordinator.beginHold()
        await eventually { capture.isRecording }
        log.events.removeAll()

        coordinator.handleSystemEvent(.outputRouteUnavailable)

        XCTAssertEqual(log.events, ["capture.cancel"])
        XCTAssertFalse(coordinator.isHolding)
        XCTAssertFalse(capture.isRecording)
    }

    func testAudioCoordinatorClearsHoldWhenRecorderCannotStart() async throws {
        let log = AudioEventLog()
        let session = FakeAudioSession(log: log)
        let capture = FakeAudioCapture(log: log)
        capture.startSucceeds = false
        let speech = SpeechPlayer(
            makePlayer: { _ in FakeSpeechAudioPlayer(log: log) },
            activateSession: { try session.activate(for: $0) }
        )
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        let coordinator = AudioCoordinator(
            recorder: capture,
            session: session,
            player: speech,
            observeNotifications: false
        )

        coordinator.beginHold()
        await eventually { !coordinator.isHolding }

        XCTAssertFalse(capture.isRecording)
        XCTAssertTrue(log.events.contains("capture.start"))
        XCTAssertEqual(speech.playingID, "reply")
    }

    func testInterruptionPolicyOnlyMapsBeganNotifications() {
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        let ended = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )

        XCTAssertEqual(AudioCoordinator.interruptionEvent(from: began), .interruptionBegan)
        XCTAssertNil(AudioCoordinator.interruptionEvent(from: ended))
    }

    func testMediaResetDiscardsCaptureObjectsAndPlayback() throws {
        let log = AudioEventLog()
        let session = FakeAudioSession(log: log)
        let capture = FakeAudioCapture(log: log)
        let speech = SpeechPlayer(
            makePlayer: { _ in FakeSpeechAudioPlayer(log: log) },
            activateSession: { try session.activate(for: $0) }
        )
        try speech.playLoadedAudio(id: "reply", data: Data([1]))
        log.events.removeAll()
        let coordinator = AudioCoordinator(
            recorder: capture,
            session: session,
            player: speech,
            observeNotifications: false
        )

        coordinator.handleSystemEvent(.mediaServicesReset)

        XCTAssertEqual(log.events, ["capture.reset", "clip.stop"])
        XCTAssertNil(coordinator.playingID)
        XCTAssertEqual(
            coordinator.recordingErrorMessage,
            "Audio services restarted. Tap and hold to begin again."
        )
    }

    func testReplyStreamsAfterPrebufferAndCompletesAfterAudioDrains() async throws {
        var renderers: [FakeSpeechRenderer] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in }
        )
        let response = speechResponse(rate: 10, chunks: [pcmData([1, 2]), pcmData([3, 4])])

        speech.playReply(id: "reply") { _ in response }
        await eventually { renderers.count == 1 && renderers[0].scheduledSamples == [1, 2, 3, 4] }

        XCTAssertEqual(speech.playingID, "reply")
        XCTAssertNil(speech.loadingID)
        XCTAssertEqual(renderers[0].playCount, 1)
        renderers[0].completeAll()
        XCTAssertNil(speech.playingID)
    }

    func testReleaseBeforePrebufferPreservesPlaybackRebuildIntent() async throws {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        let chunks = AsyncThrowingStream<Data, Error> { continuation = $0 }
        var renderers: [FakeSpeechRenderer] = []
        var intents: [AudioSessionIntent] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { intents.append($0) }
        )
        speech.playReply(id: "reply") { _ in
            SpeechResponseStream(sampleRate: 10, channels: 1, chunks: chunks)
        }
        await eventually { continuation != nil }

        speech.pauseForRecording()
        speech.resumeAfterRecording()
        continuation?.yield(pcmData([1, 2, 3]))
        continuation?.finish()
        await eventually { renderers.count == 1 }

        XCTAssertEqual(intents, [.rebuildPlayback])
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2, 3])
    }

    func testRecordingKeepsReceivingAndResumesFreshWithOneSecondRewind() async throws {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        let chunks = AsyncThrowingStream<Data, Error> { continuation = $0 }
        var renderers: [FakeSpeechRenderer] = []
        var intents: [AudioSessionIntent] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { intents.append($0) }
        )
        speech.playReply(id: "reply") { _ in
            SpeechResponseStream(sampleRate: 10, channels: 1, chunks: chunks)
        }
        continuation?.yield(pcmData(Array(0..<20).map(Int16.init)))
        await eventually { renderers.count == 1 }
        renderers[0].completeAll()
        renderers[0].playedSample = 15

        speech.pauseForRecording()
        XCTAssertTrue(renderers[0].wasStopped)
        continuation?.yield(pcmData(Array(20..<30).map(Int16.init)))
        continuation?.finish()
        await eventually { speech.loadingID == nil }
        XCTAssertEqual(renderers.count, 1, "transport must not take audio hardware during capture")

        speech.resumeAfterRecording()
        XCTAssertEqual(renderers.count, 2)
        XCTAssertEqual(renderers[1].startSample, 5)
        XCTAssertEqual(renderers[1].scheduledSamples.first, 5)
        XCTAssertEqual(intents, [.beginPlayback, .rebuildPlayback])
        let replacementSchedule = renderers[1].scheduledSamples
        renderers[0].completeAll()
        XCTAssertEqual(
            renderers[1].scheduledSamples,
            replacementSchedule,
            "A stopped renderer must not advance or refill its replacement"
        )
        XCTAssertEqual(speech.playingID, "reply")
    }

    func testInterruptionCursorCannotAdvancePastScheduledAudio() async throws {
        var renderers: [FakeSpeechRenderer] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in }
        )
        speech.playReply(id: "reply") { _ in
            self.speechResponse(rate: 10, chunks: [self.pcmData(Array(0..<20).map(Int16.init))])
        }
        await eventually { renderers.count == 1 }
        XCTAssertEqual(renderers[0].scheduledSamples.count, 10)
        renderers[0].playedSample = 100 // Simulate a node timeline running through an underrun.

        speech.pauseForRecording()
        speech.resumeAfterRecording()

        XCTAssertEqual(renderers.count, 2)
        XCTAssertEqual(renderers[1].startSample, 0, "Resume must cap at scheduled sample 10 before rewinding")
    }

    func testFailedOddByteReconnectsFromLastCompleteSample() async throws {
        var offsets: [Int] = []
        var renderers: [FakeSpeechRenderer] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in }
        )
        speech.playReply(id: "reply") { offset in
            offsets.append(offset)
            if offsets.count == 1 {
                let chunks = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(Data([1, 0, 0xaa]))
                    continuation.finish(throwing: TestStreamError.failed)
                }
                return SpeechResponseStream(sampleRate: 10, channels: 1, chunks: chunks)
            }
            return self.speechResponse(rate: 10, chunks: [Data([2, 0, 3, 0])])
        }

        await eventually { renderers.count == 1 }
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2, 3])
    }

    func testCleanOddByteEOFReconnectsFromLastCompleteSample() async throws {
        var offsets: [Int] = []
        var renderers: [FakeSpeechRenderer] = []
        let speech = SpeechPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in }
        )
        speech.playReply(id: "reply") { offset in
            offsets.append(offset)
            if offsets.count == 1 {
                return self.speechResponse(rate: 10, chunks: [Data([1, 0, 0xaa])])
            }
            return self.speechResponse(rate: 10, chunks: [Data([2, 0, 3, 0])])
        }

        await eventually { renderers.count == 1 }
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(renderers[0].scheduledSamples, [1, 2, 3])
    }

    func testRapidRecordingsUseOneUploadDrain() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://upload.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }

        let firstUploadStarted = expectation(description: "first upload started")
        let releaseFirstUpload = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var activeUploads = 0
        var maximumActiveUploads = 0
        var uploadedIDs: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                let isFirst = lock.withLock {
                    activeUploads += 1
                    maximumActiveUploads = max(maximumActiveUploads, activeUploads)
                    uploadedIDs.append(request.url!.lastPathComponent)
                    return uploadedIDs.count == 1
                }
                if isFirst {
                    firstUploadStarted.fulfill()
                    _ = releaseFirstUpload.wait(timeout: .now() + 2)
                }
                lock.withLock { activeUploads -= 1 }
                let clipID = request.url!.lastPathComponent
                let body = #"{"clip_id":"\#(clipID)","created":true}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let store = AppStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        let first = try makeRecordingForUpload()
        let second = try makeRecordingForUpload()
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }

        store.queueRecording(first)
        await fulfillment(of: [firstUploadStarted], timeout: 2)
        store.queueRecording(second)
        releaseFirstUpload.signal()

        for _ in 0..<100 where store.pendingUploadCount > 0 || store.isUploading {
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.waitForRecordingTasks()
        let (finalMaximum, finalIDs) = lock.withLock { (maximumActiveUploads, uploadedIDs) }
        XCTAssertEqual(store.pendingUploadCount, 0)
        XCTAssertEqual(finalMaximum, 1)
        XCTAssertEqual(finalIDs.sorted(), [first.id, second.id].sorted())
    }


    func testPendingSpoolPersistsDestinationAndRecordingTime() throws {
        let id = UUID().uuidString.lowercased()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PendingRecordings/recording-\(id).wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        let spool = PendingUploadSpool()
        let clip = try spool.enqueue(
            recording: LocalRecording(
                id: id, url: url, durationMs: 900, peakPct: 35, recordedAt: 4321
            ),
            serverURL: "https://wideboi.stingray-nominal.ts.net/",
            projectID: "project", conversationID: "conversation"
        )
        defer { spool.remove(clip) }
        let restored = try XCTUnwrap(spool.all().first { $0.id == id })
        XCTAssertEqual(restored.destinationKey, "project/conversation")
        XCTAssertEqual(restored.recordedAt, 4321)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.wavURL(for: restored).path))
    }

    func testSavedWatchProjectWinsOverFirstProject() throws {
        let projects = [
            KiboProject(id: "first", name: "First", created_at: 1),
            KiboProject(id: "remembered", name: "Remembered", created_at: 2),
        ]
        XCTAssertEqual(
            ProjectSelection.preferred(in: projects, savedID: "remembered")?.id,
            "remembered"
        )
        XCTAssertEqual(ProjectSelection.preferred(in: projects, savedID: "missing")?.id, "first")
    }


    private func makeRecordingForUpload() throws -> LocalRecording {
        let id = UUID().uuidString.lowercased()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording-\(id).wav")
        try Data(repeating: 0, count: 44).write(to: url)
        return LocalRecording(id: id, url: url, durationMs: 800, peakPct: 20, recordedAt: 1)
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

    private func speechResponse(rate: Int, chunks: [Data]) -> SpeechResponseStream {
        SpeechResponseStream(
            sampleRate: rate,
            channels: 1,
            chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { sample in
            let value = UInt16(bitPattern: sample)
            return [UInt8(value & 0xff), UInt8(value >> 8)]
        })
    }
}

@MainActor
private final class FakeSpeechAudioPlayer: SpeechAudioPlaying {
    private let log: AudioEventLog?
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var didFinish: (() -> Void)?
    private(set) var playCount = 0
    private(set) var wasStopped = false

    init(log: AudioEventLog? = nil) {
        self.log = log
    }

    func prepareToPlay() {}
    func play() -> Bool {
        log?.events.append("clip.play")
        playCount += 1
        isPlaying = true
        return true
    }
    func stop() {
        log?.events.append("clip.stop")
        wasStopped = true
        isPlaying = false
    }
}

@MainActor
private final class AudioEventLog {
    var events: [String] = []
}

@MainActor
private final class FakeAudioSession: AudioSessionControlling {
    private let log: AudioEventLog
    var failingIntent: AudioSessionIntent?

    init(log: AudioEventLog) { self.log = log }

    func activate(for intent: AudioSessionIntent) throws {
        log.events.append("session.activate:\(intent)")
        if failingIntent == intent { throw TestAudioError.sessionActivation }
    }

    func deactivate() {
        log.events.append("session.deactivate")
    }
}

@MainActor
private final class FakeAudioCapture: AudioCapturing {
    let objectWillChange = ObservableObjectPublisher()
    private let log: AudioEventLog
    var isRecording = false
    var isStarting = false
    var level: CGFloat = 0
    var errorMessage: String?
    var startSucceeds = true

    init(log: AudioEventLog) { self.log = log }

    func prepare() async { log.events.append("capture.prepare") }

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

    func resetAudioObjects() {
        log.events.append("capture.reset")
        isRecording = false
    }
}

private enum TestAudioError: Error {
    case sessionActivation
}

@MainActor
private final class FakeSpeechRenderer: SpeechRendering {
    let sampleRate: Int
    let startSample: Int
    var playedSample: Int
    private(set) var scheduledSamples: [Int16] = []
    private(set) var playCount = 0
    private(set) var wasStopped = false
    private var isPlaying = false
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
    ) throws {
        scheduledSamples.append(contentsOf: samples)
        completions.append((startSample + samples.count, onPlayed))
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playCount += 1
    }
    func stop() {
        isPlaying = false
        wasStopped = true
    }

    func completeAll() {
        let pending = completions
        completions = []
        for (end, completion) in pending {
            playedSample = max(playedSample, end)
            completion(end)
        }
    }
}

private enum TestStreamError: Error {
    case failed
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
