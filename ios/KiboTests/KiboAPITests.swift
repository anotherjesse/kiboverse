@preconcurrency import AVFoundation
import Combine
import XCTest
@testable import Kibo

@MainActor
final class KiboAPITests: XCTestCase {
    private var session: URLSession!

    func testReplyAutoplayGateRequiresSafeVisibleAudioScope() {
        XCTAssertTrue(ReplyAutoplayGate(
            sceneIsActive: true,
            systemPlaybackSuspended: false,
            captureIsActive: false,
            overlayIsPresented: false
        ).allowsPlayback)

        for gate in [
            ReplyAutoplayGate(
                sceneIsActive: false, systemPlaybackSuspended: false,
                captureIsActive: false, overlayIsPresented: false
            ),
            ReplyAutoplayGate(
                sceneIsActive: true, systemPlaybackSuspended: true,
                captureIsActive: false, overlayIsPresented: false
            ),
            ReplyAutoplayGate(
                sceneIsActive: true, systemPlaybackSuspended: false,
                captureIsActive: true, overlayIsPresented: false
            ),
            ReplyAutoplayGate(
                sceneIsActive: true, systemPlaybackSuspended: false,
                captureIsActive: false, overlayIsPresented: true
            ),
        ] {
            XCTAssertFalse(gate.allowsPlayback)
        }
    }

    func testReplyLifecycleSuspensionRearmsTheSameDurableSpeechEvent() throws {
        var lifecycle = ReplyLifecycle()
        lifecycle.appear(isActive: true)
        lifecycle.awaitReply(
            to: "t1",
            destination: KiboDestination(
                serverURL: "https://one.example/",
                projectID: "p1",
                conversationID: "c1"
            )
        )
        lifecycle.markPlaybackAttempt(speechEventSeq: 3)

        lifecycle.becomeInactive()

        XCTAssertEqual(lifecycle.awaitedTurnID, "t1")
        XCTAssertNil(lifecycle.attemptedSpeechEventSeq)
        lifecycle.becomeActive()
        let data = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(
            events.replyAutoPlayAction(
                for: "t1",
                attemptedSpeechEventSeq: lifecycle.attemptedSpeechEventSeq,
                loadingID: nil,
                playingID: nil,
                lastFinishedID: nil
            ),
            .startPlayback(speechEventSeq: 3)
        )
    }

    func testReplyLifecycleInvalidatesCommandsBeforeEveryTeardown() {
        let destination = KiboDestination(
            serverURL: "https://one.example/",
            projectID: "p1",
            conversationID: "c1"
        )
        var lifecycle = ReplyLifecycle()
        lifecycle.appear(isActive: true)
        let first = lifecycle.beginCommand(destination: destination)!
        let replacement = lifecycle.beginCommand(destination: destination)!
        XCTAssertFalse(lifecycle.accepts(first, destination: destination))
        XCTAssertTrue(lifecycle.accepts(replacement, destination: destination))

        lifecycle.awaitReply(to: "turn-1", destination: destination)
        lifecycle.markPlaybackAttempt(speechEventSeq: 7)
        lifecycle.becomeInactive()
        XCTAssertFalse(lifecycle.accepts(replacement, destination: destination))
        XCTAssertEqual(lifecycle.awaitedTurnID, "turn-1")
        XCTAssertNil(lifecycle.attemptedSpeechEventSeq)
        XCTAssertFalse(lifecycle.allowsPlayback)

        lifecycle.becomeActive()
        let foreground = lifecycle.beginCommand(destination: destination)!
        lifecycle.selectionChanged()
        XCTAssertFalse(lifecycle.accepts(foreground, destination: destination))
        XCTAssertNil(lifecycle.awaitedTurnID)

        lifecycle.disappear()
        XCTAssertFalse(lifecycle.allowsPlayback)
        XCTAssertNil(lifecycle.beginCommand(destination: destination))
    }

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

    func testExplicitRetryCommandsUseDedicatedEndpoints() async throws {
        let lock = NSLock()
        var paths: [String] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            lock.withLock { paths.append(request.url!.path) }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 202,
                    httpVersion: nil, headerFields: nil
                )!,
                Data()
            )
        }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        try await api.retryClip(projectID: "p", conversationID: "c", clipID: "clip-1")
        try await api.retryTurn(projectID: "p", conversationID: "c", turnID: "turn-1")

        XCTAssertEqual(lock.withLock { paths }, [
            "/v1/projects/p/conversations/c/clips/clip-1/retry",
            "/v1/projects/p/conversations/c/turns/turn-1/retry",
        ])
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

    func testClipUploadRejectsMismatchedReceipt() async throws {
        StubURLProtocol.handler = { request in
            let body = #"{"clip_id":"some-other-clip","created":true}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 201,
                    httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 44).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        do {
            try await api.uploadClip(
                fileURL: url, projectID: "p", conversationID: "c", clipID: "clip-1",
                durationMs: 875, peakPct: 42, recordedAt: 1234
            )
            XCTFail("A receipt for a different clip must not acknowledge this recording")
        } catch APIError.invalidResponse {
            // Expected.
        }
    }

    func testClipUploadRejectsAudioChangedSinceEnqueue() async throws {
        StubURLProtocol.handler = { request in
            XCTFail("Changed audio must not reach the network")
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil
                )!,
                Data()
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 44).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test", session: session)

        do {
            try await api.uploadClip(
                fileURL: url, projectID: "p", conversationID: "c", clipID: "clip-1",
                durationMs: 875, peakPct: 42, recordedAt: 1234,
                expectedSHA256: String(repeating: "0", count: 64)
            )
            XCTFail("Changed audio must be retained for recovery")
        } catch APIError.localRecordingChanged {
            // Expected.
        }
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
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Speech-Generation"),
                "generation-1"
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
            destination: KiboDestination(
                serverURL: "https://example.test/",
                projectID: "p",
                conversationID: "c"
            ),
            turnID: "t",
            fromSample: 17,
            generation: "generation-1"
        )
        var body = Data()
        for try await chunk in response.chunks { body.append(chunk) }
        XCTAssertEqual(response.sampleRate, 24_000)
        XCTAssertEqual(response.channels, 1)
        XCTAssertEqual(response.generation, "legacy")
        XCTAssertEqual(body, Data([1, 0, 2, 0]))
    }

    func testReplyReconnectKeepsItsImmutableDestinationAfterSelectionChanges() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://reply-owner.test/", forKey: "serverURL")
        defer {
            if let savedServerURL {
                UserDefaults.standard.set(savedServerURL, forKey: "serverURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "serverURL")
            }
        }

        let lock = NSLock()
        var requestPaths: [String] = []
        StubURLProtocol.handler = { request in
            lock.withLock { requestPaths.append(request.url!.path) }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil
                )!,
                Data()
            )
        }

        let firstRetry = expectation(description: "first stream load failed")
        var mayRetry = false
        var retryFailures: [Int] = []
        let store = AppStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "old-conversation"
        let destination = try XCTUnwrap(store.requestDestination)
        let speech = SpeechPlayer(
            activateSession: { _ in },
            retryDelay: { failures in
                retryFailures.append(failures)
                if failures == 1 {
                    firstRetry.fulfill()
                    while !mayRetry { await Task.yield() }
                }
            }
        )

        speech.playReply(turnID: "shared-turn", destination: destination, store: store)
        await fulfillment(of: [firstRetry], timeout: 1)
        XCTAssertEqual(speech.loadingID, "reply-shared-turn")
        store.selectedConversationID = "new-conversation"
        mayRetry = true

        await eventually { speech.loadingID == nil }
        XCTAssertEqual(retryFailures, [1])
        XCTAssertEqual(lock.withLock { requestPaths }, [
            "/v1/projects/project/conversations/old-conversation/turns/shared-turn/speech",
        ])
        XCTAssertNil(speech.errorMessage)
    }

    func testTimelineBuildsPersonAndReplyCards() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript","clip":"c1","text":"Hello"},{"seq":3,"kind":"turn","id":"t1","clips":["c1"]},{"seq":4,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":5,"kind":"speech_started","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.timeline().map(\.body), ["Hello", "Hi"])
        XCTAssertTrue(events.timeline().last?.canPlay == true)
    }

    func testTimelineSplitsEachRecordingIntoItsOwnCard() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1","ms":1500},{"seq":2,"kind":"clip","id":"c2","ms":900},{"seq":3,"kind":"transcript","clip":"c1","text":"First"},{"seq":4,"kind":"transcript","clip":"c2","text":"Second"},{"seq":5,"kind":"turn","id":"t1","clips":["c1","c2"]},{"seq":6,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":7,"kind":"speech_ready","turn":"t1"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        let cards = events.timeline()
        XCTAssertEqual(cards.map(\.body), ["First", "Second", "Hi"])
        XCTAssertEqual(cards.compactMap(\.clipID), ["c1", "c2"])
        XCTAssertEqual(cards.first?.durationMs, 1500)
        XCTAssertTrue(cards.allSatisfy { $0.role == .kibo || $0.canPlay })
    }

    func testTerminalFailureIsAbsorbingUntilExplicitRetry() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_error","clip":"c1","error":"first","terminal":true},{"seq":3,"kind":"transcript_error","clip":"c1","error":"latest","terminal":true}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.timeline().single?.body, "first")
        XCTAssertEqual(events.retryableFailure, .clip("c1"))

        let recoveredData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_error","clip":"c1","error":"first","terminal":true},{"seq":3,"kind":"transcript_started","clip":"c1","attempt":2},{"seq":4,"kind":"transcript","clip":"c1","text":"ignored"},{"seq":5,"kind":"transcript_retry_requested","clip":"c1"},{"seq":6,"kind":"transcript","clip":"c1","text":"Recovered"}]"#.data(using: .utf8)!
        let recovered = try JSONDecoder().decode([KiboEvent].self, from: recoveredData)
        XCTAssertEqual(recovered.timeline().single?.body, "Recovered")
    }

    func testSuccessfulTextStagesRemainAuthoritativeAcrossStaleEvents() throws {
        let staleTranscriptData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript","clip":"c1","text":"First"},{"seq":3,"kind":"transcript_retry_scheduled","clip":"c1"},{"seq":4,"kind":"transcript_error","clip":"c1","error":"stale"},{"seq":5,"kind":"transcript","clip":"c1","text":"ignored"}]"#.data(using: .utf8)!
        let staleTranscript = try JSONDecoder().decode([KiboEvent].self, from: staleTranscriptData)
        XCTAssertEqual(staleTranscript.timeline().single?.body, "First")

        let transcriptData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript","clip":"c1","text":"First"},{"seq":3,"kind":"transcript_retry_scheduled","clip":"c1"},{"seq":4,"kind":"transcript_error","clip":"c1","error":"stale"},{"seq":5,"kind":"transcript","clip":"c1","text":"ignored"},{"seq":6,"kind":"transcript_retry_requested","clip":"c1"},{"seq":7,"kind":"transcript","clip":"c1","text":"Replaced"}]"#.data(using: .utf8)!
        let transcript = try JSONDecoder().decode([KiboEvent].self, from: transcriptData)
        XCTAssertEqual(transcript.timeline().single?.body, "First")

        let staleReplyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"First"},{"seq":3,"kind":"reply_retry_scheduled","turn":"t1"},{"seq":4,"kind":"reply_error","turn":"t1","error":"stale"},{"seq":5,"kind":"reply","turn":"t1","text":"ignored"}]"#.data(using: .utf8)!
        let staleReply = try JSONDecoder().decode([KiboEvent].self, from: staleReplyData)
        XCTAssertEqual(staleReply.timeline().single?.body, "First")

        let replyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"First"},{"seq":3,"kind":"reply_retry_scheduled","turn":"t1"},{"seq":4,"kind":"reply_error","turn":"t1","error":"stale"},{"seq":5,"kind":"reply","turn":"t1","text":"ignored"},{"seq":6,"kind":"reply_retry_requested","turn":"t1"},{"seq":7,"kind":"reply","turn":"t1","text":"Replaced"}]"#.data(using: .utf8)!
        let reply = try JSONDecoder().decode([KiboEvent].self, from: replyData)
        XCTAssertEqual(reply.timeline().single?.body, "First")
    }

    func testPendingTurnEndsWhenReplyArrives() throws {
        let pendingData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]}]"#.data(using: .utf8)!
        let pending = try JSONDecoder().decode([KiboEvent].self, from: pendingData)
        XCTAssertEqual(pending.pendingTurnIDs, ["t1"])

        let finishedData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Done"}]"#.data(using: .utf8)!
        let finished = try JSONDecoder().decode([KiboEvent].self, from: finishedData)
        XCTAssertTrue(finished.pendingTurnIDs.isEmpty)
    }

    func testRetryEventsDistinguishInitialWorkFromRetrying() throws {
        let initialData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_started","clip":"c1","attempt":1},{"seq":3,"kind":"turn","id":"t1","clips":["c1"]},{"seq":4,"kind":"reply_started","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let initial = try JSONDecoder().decode([KiboEvent].self, from: initialData)
        XCTAssertEqual(initial.timeline().map(\.body), ["Transcribing…", "Thinking…"])

        let retryingData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_started","clip":"c1","attempt":1},{"seq":3,"kind":"transcript_retry_scheduled","clip":"c1","attempt":1},{"seq":4,"kind":"turn","id":"t1","clips":["c1"]},{"seq":5,"kind":"reply_started","turn":"t1","attempt":1},{"seq":6,"kind":"reply_retry_scheduled","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let retrying = try JSONDecoder().decode([KiboEvent].self, from: retryingData)
        XCTAssertEqual(retrying.pendingTurnIDs, ["t1"])
        XCTAssertEqual(retrying.timeline().map(\.body), ["Retrying transcription…", "Retrying…"])

        let attemptData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply_started","turn":"t1","attempt":2}]"#.data(using: .utf8)!
        let attempt = try JSONDecoder().decode([KiboEvent].self, from: attemptData)
        XCTAssertEqual(attempt.timeline().single?.body, "Retrying…")

        let speechAttemptData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_retry_scheduled","turn":"t1"},{"seq":4,"kind":"speech_started","turn":"t1","attempt":2}]"#.data(using: .utf8)!
        let speechAttempt = try JSONDecoder().decode([KiboEvent].self, from: speechAttemptData)
        XCTAssertEqual(speechAttempt.timeline().single?.body, "Hi\n\nRetrying speech…")
        XCTAssertEqual(speechAttempt.replyReadiness(for: "t1"), .playable)
    }

    func testLegacyNonterminalErrorsRemainRetryableAndAcceptRecovery() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_error","clip":"c1","error":"offline"},{"seq":3,"kind":"transcript_started","clip":"c1","attempt":2},{"seq":4,"kind":"transcript","clip":"c1","text":"Recovered input"},{"seq":5,"kind":"turn","id":"t1","clips":["c1"]},{"seq":6,"kind":"reply_error","turn":"t1","error":"offline","terminal":false},{"seq":7,"kind":"reply_started","turn":"t1","attempt":2},{"seq":8,"kind":"reply","turn":"t1","text":"Recovered reply","audio":"tts/t1.wav"},{"seq":9,"kind":"tts_error","turn":"t1","error":"offline"},{"seq":10,"kind":"speech_started","turn":"t1","attempt":2},{"seq":11,"kind":"speech_ready","turn":"t1"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        XCTAssertTrue(events.pendingTurnIDs.isEmpty)
        XCTAssertEqual(events.timeline().map(\.body), ["Recovered input", "Recovered reply"])
        XCTAssertTrue(events.timeline().last?.canPlay == true)
        XCTAssertNil(events.retryableFailure)
    }

    func testDurableRetrySupersedesTerminalTranscriptFailure() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript_error","clip":"c1","error":"broken","terminal":true},{"seq":3,"kind":"transcript_retry_requested","clip":"c1"},{"seq":4,"kind":"transcript","clip":"c1","text":"Recovered"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        XCTAssertEqual(events.timeline().single?.body, "Recovered")
    }

    func testTranscriptRetryReopensItsTranscriptionFailedTurn() throws {
        let retryingData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"turn","id":"t1","clips":["c1"]},{"seq":3,"kind":"transcript_error","clip":"c1","error":"broken","terminal":true},{"seq":4,"kind":"reply_error","turn":"t1","stage":"transcription","error":"broken","terminal":true},{"seq":5,"kind":"transcript_retry_requested","clip":"c1"}]"#.data(using: .utf8)!
        let waiting = try JSONDecoder().decode([KiboEvent].self, from: retryingData)
        XCTAssertEqual(waiting.pendingTurnIDs, ["t1"])
        XCTAssertEqual(waiting.timeline().map(\.body), ["Retrying transcription…", "Retrying…"])

        let recoveredData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"turn","id":"t1","clips":["c1"]},{"seq":3,"kind":"transcript_error","clip":"c1","error":"broken","terminal":true},{"seq":4,"kind":"reply_error","turn":"t1","stage":"transcription","error":"broken","terminal":true},{"seq":5,"kind":"transcript_retry_requested","clip":"c1"},{"seq":6,"kind":"transcript","clip":"c1","text":"Fixed"},{"seq":7,"kind":"reply_started","turn":"t1","attempt":1},{"seq":8,"kind":"reply","turn":"t1","text":"Recovered","audio":"tts/t1.wav"}]"#.data(using: .utf8)!
        let recovered = try JSONDecoder().decode([KiboEvent].self, from: recoveredData)
        XCTAssertTrue(recovered.pendingTurnIDs.isEmpty)
        XCTAssertEqual(recovered.timeline().map(\.body), ["Fixed", "Recovered"])
    }

    func testTranscriptSuccessWaitsForEveryClaimedClipBeforeReopeningReply() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"clip","id":"c2"},{"seq":3,"kind":"turn","id":"t1","clips":["c1","c2"]},{"seq":4,"kind":"transcript_error","clip":"c1","error":"still broken","terminal":true},{"seq":5,"kind":"reply_error","turn":"t1","stage":"transcription","error":"claimed clip failed","terminal":true},{"seq":6,"kind":"transcript","clip":"c2","text":"Healthy sibling"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)

        XCTAssertTrue(events.pendingTurnIDs.isEmpty)
        XCTAssertEqual(events.retryableFailure, .turn("t1"))
        XCTAssertEqual(events.timeline().map(\.body), ["still broken", "Healthy sibling", "claimed clip failed"])
    }

    func testRepeatedTerminalTranscriptFailureClosesReopenedTurn() throws {
        let retryFailedData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"turn","id":"t1","clips":["c1"]},{"seq":3,"kind":"transcript_error","clip":"c1","error":"broken","terminal":true},{"seq":4,"kind":"reply_error","turn":"t1","stage":"transcription","error":"broken","terminal":true},{"seq":5,"kind":"transcript_retry_requested","clip":"c1"},{"seq":6,"kind":"transcript_started","clip":"c1","attempt":1},{"seq":7,"kind":"transcript_error","clip":"c1","error":"still broken","terminal":true}]"#.data(using: .utf8)!
        let stillPending = try JSONDecoder().decode([KiboEvent].self, from: retryFailedData)
        XCTAssertEqual(stillPending.pendingTurnIDs, ["t1"])

        let closedData = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"turn","id":"t1","clips":["c1"]},{"seq":3,"kind":"transcript_error","clip":"c1","error":"broken","terminal":true},{"seq":4,"kind":"reply_error","turn":"t1","stage":"transcription","error":"broken","terminal":true},{"seq":5,"kind":"transcript_retry_requested","clip":"c1"},{"seq":6,"kind":"transcript_started","clip":"c1","attempt":1},{"seq":7,"kind":"transcript_error","clip":"c1","error":"still broken","terminal":true},{"seq":8,"kind":"reply_error","turn":"t1","stage":"transcription","error":"still broken","terminal":true}]"#.data(using: .utf8)!
        let closed = try JSONDecoder().decode([KiboEvent].self, from: closedData)
        XCTAssertTrue(closed.pendingTurnIDs.isEmpty)
        XCTAssertEqual(closed.retryableFailure, .turn("t1"))
        XCTAssertEqual(closed.timeline().map(\.body), ["still broken", "still broken"])
    }

    func testSpeechRetryRequiresAdvertisedAndExistingSpeech() throws {
        let audioLessData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Text only"},{"seq":3,"kind":"speech_retry_requested","turn":"t1"}]"#.data(using: .utf8)!
        let audioLess = try JSONDecoder().decode([KiboEvent].self, from: audioLessData)
        XCTAssertEqual(audioLess.timeline().single?.body, "Text only")

        let readyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Spoken","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1},{"seq":4,"kind":"speech_ready","turn":"t1"},{"seq":5,"kind":"speech_retry_requested","turn":"t1"}]"#.data(using: .utf8)!
        let ready = try JSONDecoder().decode([KiboEvent].self, from: readyData)
        XCTAssertEqual(ready.timeline().single?.body, "Spoken\n\nRetrying speech…")
        XCTAssertEqual(ready.replyReadiness(for: "t1"), .waiting)
    }

    func testReplyWaitsForSpeechEndpointAndAutoplayKeepsAwaitingWhileLoading() throws {
        let replyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Text survives","audio":"tts/t1.wav"}]"#.data(using: .utf8)!
        let reply = try JSONDecoder().decode([KiboEvent].self, from: replyData)
        XCTAssertEqual(reply.replyReadiness(for: "t1"), .waiting)
        XCTAssertFalse(reply.timeline().last?.canPlay == true)

        let streamingData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Text survives","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let streaming = try JSONDecoder().decode([KiboEvent].self, from: streamingData)
        XCTAssertEqual(streaming.replyReadiness(for: "t1"), .playable)
        XCTAssertEqual(
            streaming.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: nil,
                loadingID: nil, playingID: nil, lastFinishedID: nil
            ),
            .startPlayback(speechEventSeq: 3)
        )
        XCTAssertEqual(
            streaming.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: "reply-t1", playingID: nil, lastFinishedID: nil
            ),
            .wait,
            "A 425 retry remains a live loading request and must not clear autoplay"
        )
        XCTAssertEqual(
            streaming.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: nil, playingID: "reply-t1", lastFinishedID: nil
            ),
            .wait,
            "Audible playback is not durable lifecycle completion"
        )
    }

    func testAutoplayOwnershipSurvivesFailedStreamUntilLifecycleRecoveryCompletes() throws {
        let startedData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let started = try JSONDecoder().decode([KiboEvent].self, from: startedData)
        XCTAssertEqual(
            started.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: nil, playingID: nil, lastFinishedID: nil
            ),
            .wait,
            "A failed transport must wait for a new durable speech event instead of looping"
        )

        let scheduledData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1},{"seq":4,"kind":"speech_retry_scheduled","turn":"t1","attempt":1}]"#.data(using: .utf8)!
        let scheduled = try JSONDecoder().decode([KiboEvent].self, from: scheduledData)
        XCTAssertEqual(
            scheduled.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: nil, playingID: nil, lastFinishedID: nil
            ),
            .wait
        )

        let restartedData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1},{"seq":4,"kind":"speech_retry_scheduled","turn":"t1","attempt":1},{"seq":5,"kind":"speech_started","turn":"t1","attempt":2}]"#.data(using: .utf8)!
        let restarted = try JSONDecoder().decode([KiboEvent].self, from: restartedData)
        XCTAssertEqual(
            restarted.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 3,
                loadingID: nil, playingID: nil, lastFinishedID: nil
            ),
            .startPlayback(speechEventSeq: 5)
        )

        let readyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_started","turn":"t1","attempt":1},{"seq":4,"kind":"speech_retry_scheduled","turn":"t1","attempt":1},{"seq":5,"kind":"speech_started","turn":"t1","attempt":2},{"seq":6,"kind":"speech_ready","turn":"t1"}]"#.data(using: .utf8)!
        let ready = try JSONDecoder().decode([KiboEvent].self, from: readyData)
        XCTAssertEqual(
            ready.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 5,
                loadingID: nil, playingID: "reply-t1", lastFinishedID: nil
            ),
            .wait
        )
        XCTAssertEqual(
            ready.replyAutoPlayAction(
                for: "t1", attemptedSpeechEventSeq: 5,
                loadingID: nil, playingID: nil, lastFinishedID: "reply-t1"
            ),
            .complete
        )
    }

    func testSuccessfulSpeechIsAbsorbingUntilExplicitRetry() throws {
        let readyData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Text survives","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_ready","turn":"t1"},{"seq":4,"kind":"tts_error","turn":"t1","error":"stale","terminal":false}]"#.data(using: .utf8)!
        let ready = try JSONDecoder().decode([KiboEvent].self, from: readyData)
        XCTAssertEqual(ready.replyReadiness(for: "t1"), .playable)
        XCTAssertTrue(ready.timeline().last?.canPlay == true)

        let failedData = #"[{"seq":1,"kind":"turn","id":"t1","clips":[]},{"seq":2,"kind":"reply","turn":"t1","text":"Text survives","audio":"tts/t1.wav"},{"seq":3,"kind":"speech_ready","turn":"t1"},{"seq":4,"kind":"speech_retry_requested","turn":"t1"},{"seq":5,"kind":"tts_error","turn":"t1","error":"broken","terminal":true}]"#.data(using: .utf8)!
        let failed = try JSONDecoder().decode([KiboEvent].self, from: failedData)

        XCTAssertEqual(failed.replyReadiness(for: "t1"), .failed)
        XCTAssertEqual(failed.timeline().last?.body, "Text survives\n\nSpeech unavailable: broken")
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

    func testSystemRouteLossPreservesCaptureWithoutResumingPlayback() async throws {
        let log = AudioEventLog()
        var inventoryRefreshes = 0
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
            observeNotifications: false,
            recordingInventoryDidChange: { inventoryRefreshes += 1 }
        )
        coordinator.beginHold()
        await eventually { capture.isRecording }
        log.events.removeAll()

        coordinator.handleSystemEvent(.outputRouteUnavailable)

        XCTAssertTrue(coordinator.automaticPlaybackSuspended)
        XCTAssertEqual(log.events, ["capture.preserve"])
        XCTAssertEqual(inventoryRefreshes, 1)
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

        speech.playReply(id: "reply") { _, _ in response }
        await eventually { renderers.count == 1 && renderers[0].scheduledSamples == [1, 2, 3, 4] }

        XCTAssertEqual(speech.playingID, "reply")
        XCTAssertNil(speech.loadingID)
        XCTAssertEqual(renderers[0].playCount, 1)
        renderers[0].completeAll()
        XCTAssertNil(speech.playingID)
    }

    func testTooEarlySpeechStreamRetriesWhileRequestRemainsLoading() async {
        var attempts = 0
        var loadingDuringGap: String?
        var renderers: [FakeSpeechRenderer] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in },
            retryDelay: { _ in }
        )

        player.play(id: "reply-t1") { _, _ in
            attempts += 1
            if attempts == 1 {
                loadingDuringGap = player.loadingID
                throw APIError.server(425, "speech is not ready yet")
            }
            return self.speechResponse(rate: 10, chunks: [self.pcmData([1, 2, 3, 4])])
        }

        await eventually { renderers.count == 1 }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(loadingDuringGap, "reply-t1")
        XCTAssertEqual(player.playingID, "reply-t1")
        XCTAssertNil(player.errorMessage)
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
        speech.playReply(id: "reply") { _, _ in
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
        speech.playReply(id: "reply") { _, _ in
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
        speech.playReply(id: "reply") { _, _ in
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
        speech.playReply(id: "reply") { offset, _ in
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

    func testNewSpeechGenerationDiscardsEarlierAttemptAndRestartsAtZero() async throws {
        var offsets: [Int] = []
        var expectedGenerations: [String?] = []
        var renderers: [FakeSpeechRenderer] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in },
            retryDelay: { _ in }
        )

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
                        continuation.yield(self.pcmData([1, 2, 3, 4]))
                        continuation.finish(throwing: TestStreamError.failed)
                    }
                )
            case 2:
                return SpeechResponseStream(
                    generation: "attempt-2",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcmData([99]))
                        continuation.finish()
                    }
                )
            default:
                return SpeechResponseStream(
                    generation: "attempt-2",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcmData([10, 11, 12, 13]))
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

    func testGenerationPreconditionFailureResetsLedgerAndExpectedToken() async throws {
        var offsets: [Int] = []
        var expectedGenerations: [String?] = []
        var renderers: [FakeSpeechRenderer] = []
        let player = PCMStreamingPlayer(
            makeRenderer: { rate, start in
                let renderer = FakeSpeechRenderer(sampleRate: rate, startSample: start)
                renderers.append(renderer)
                return renderer
            },
            activateSession: { _ in },
            retryDelay: { _ in }
        )

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
                        continuation.yield(self.pcmData([1, 2, 3, 4]))
                        continuation.finish(throwing: TestStreamError.failed)
                    }
                )
            case 2:
                throw APIError.speechGenerationChanged
            default:
                return SpeechResponseStream(
                    generation: "attempt-2",
                    sampleRate: 10,
                    channels: 1,
                    chunks: AsyncThrowingStream { continuation in
                        continuation.yield(self.pcmData([10, 11, 12, 13]))
                        continuation.finish()
                    }
                )
            }
        }

        await eventually { renderers.count == 2 }
        XCTAssertEqual(offsets, [0, 4, 0])
        XCTAssertEqual(expectedGenerations, [nil, "attempt-1", nil])
        XCTAssertTrue(renderers[0].wasStopped)
        XCTAssertEqual(renderers[1].scheduledSamples, [10, 11, 12, 13])
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
        speech.playReply(id: "reply") { offset, _ in
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

    func testSubmitTurnStopsWhenRetryQuarantinesChangedRecording() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://quarantine.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        let lock = NSLock()
        var putCount = 0
        var postCount = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                lock.withLock { putCount += 1 }
                let body = #"{"error":"temporarily offline"}"#.data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 503,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            if request.httpMethod == "POST" {
                lock.withLock { postCount += 1 }
                let body = #"{"turn_id":"unexpected","clips":[],"created":true}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 202,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        let store = AppStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        let recording = try makeRecordingForUpload()
        defer {
            store.discardPendingUploads()
            try? FileManager.default.removeItem(at: recording.url)
        }

        store.queueRecording(recording)
        await store.waitForRecordingTasks()
        try Data(repeating: 1, count: 44).write(to: recording.url)

        let turnID = await store.submitTurn()
        let counts = lock.withLock { (putCount, postCount) }

        XCTAssertNil(turnID)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(store.recoveryItemCount, 1)
    }

    func testServerChangeCannotStraddleAnAcceptedRetry() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://old-retry.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }

        let retryStarted = expectation(description: "retry started")
        let releaseRetry = DispatchSemaphore(value: 0)
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.host, "old-retry.test")
                retryStarted.fulfill()
                _ = releaseRetry.wait(timeout: .now() + 2)
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 202,
                        httpVersion: nil, headerFields: nil
                    )!,
                    Data()
                )
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        let store = AppStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        let retry = Task { await store.retryFailedWork(.turn("turn-1")) }
        await fulfillment(of: [retryStarted], timeout: 2)

        let changed = await store.updateServerURL("https://new-retry.test/")

        XCTAssertFalse(changed)
        XCTAssertEqual(store.serverURL, "https://old-retry.test/")
        releaseRetry.signal()
        await retry.value
    }

    func testServerChangeCannotStraddleProjectCreation() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://old-create.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }

        let createStarted = expectation(description: "project create started")
        let releaseCreate = DispatchSemaphore(value: 0)
        defer { releaseCreate.signal() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "old-create.test")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/projects"):
                createStarted.fulfill()
                _ = releaseCreate.wait(timeout: .now() + 2)
                let body = #"{"id":"bedroom","name":"Bedroom","created_at":1}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 201,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            case ("GET", "/v1/projects"):
                let body = #"{"projects":[{"id":"bedroom","name":"Bedroom","created_at":1}]}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            case ("GET", "/v1/projects/bedroom/conversations"):
                let body = #"{"conversations":[]}"#.data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw URLError(.unsupportedURL)
            }
        }

        let store = AppStore(session: session)
        let creation = Task { await store.createProject(name: "Bedroom") }
        await fulfillment(of: [createStarted], timeout: 2)

        let changed = await store.updateServerURL("https://new-create.test/")

        XCTAssertFalse(changed)
        XCTAssertEqual(store.serverURL, "https://old-create.test/")
        releaseCreate.signal()
        await creation.value
        XCTAssertEqual(store.selectedProjectID, "bedroom")
        XCTAssertEqual(store.projects.map(\.id), ["bedroom"])
    }

    func testConversationCreateCompletionRejectsAwayAndBackSelectionABA() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://conversation-create.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }

        let createStarted = expectation(description: "conversation create started")
        let releaseCreate = DispatchSemaphore(value: 0)
        defer { releaseCreate.signal() }
        let lock = NSLock()
        var conversationListReads = 0
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST" && path == "/v1/projects/p1/conversations" {
                createStarted.fulfill()
                _ = releaseCreate.wait(timeout: .now() + 2)
                let body = #"{"id":"created","project_id":"p1","name":"Created","name_source":"manual","created_at":2,"last_activity_at":2}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 201,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            if request.httpMethod == "GET" && path == "/v1/projects/p1/conversations" {
                lock.withLock { conversationListReads += 1 }
                let body = #"{"conversations":[{"id":"created","project_id":"p1","name":"Created","name_source":"manual","created_at":2,"last_activity_at":2}]}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            if request.httpMethod == "GET" && path.hasSuffix("/events") {
                let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
            throw URLError(.unsupportedURL)
        }

        let store = AppStore(session: session)
        store.selectedProjectID = "p1"
        store.selectedConversationID = "original"
        store.conversations = [
            KiboConversation(
                id: "original", project_id: "p1", name: "Original",
                name_source: .manual, created_at: 1, last_activity_at: 1
            ),
            KiboConversation(
                id: "other", project_id: "p1", name: "Other",
                name_source: .manual, created_at: 1, last_activity_at: 1
            ),
        ]
        let creation = Task { await store.createConversation(name: "Created") }
        await fulfillment(of: [createStarted], timeout: 2)

        let away = Task { await store.selectConversation("other") }
        await eventually { store.selectedConversationID == "other" }
        let back = Task { await store.selectConversation("original") }
        await eventually { store.selectedConversationID == "original" }
        releaseCreate.signal()
        await away.value
        await back.value
        await creation.value

        XCTAssertEqual(store.selectedConversationID, "original")
        XCTAssertEqual(store.conversations.map(\.id), ["original", "other"])
        XCTAssertEqual(lock.withLock { conversationListReads }, 0)
    }

    func testSubmitTurnDoesNotReturnOrRefreshAfterSelectionChanges() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://submit-selection.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }

        let submitStarted = expectation(description: "turn submit started")
        let releaseSubmit = DispatchSemaphore(value: 0)
        defer { releaseSubmit.signal() }
        let lock = NSLock()
        var eventReads = 0
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST" && path.hasSuffix("/turns") {
                XCTAssertTrue(path.contains("/conversations/original/"))
                submitStarted.fulfill()
                _ = releaseSubmit.wait(timeout: .now() + 2)
                let body = #"{"turn_id":"accepted","clips":[],"created":true}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 202,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            if request.httpMethod == "GET" && path.hasSuffix("/events") {
                lock.withLock { eventReads += 1 }
                let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
            throw URLError(.unsupportedURL)
        }

        let store = AppStore(session: session)
        store.discardPendingUploads()
        store.selectedProjectID = "p1"
        store.selectedConversationID = "original"
        let submission = Task { await store.submitTurn() }
        await fulfillment(of: [submitStarted], timeout: 2)

        let selection = Task { await store.selectConversation("replacement") }
        await eventually { store.selectedConversationID == "replacement" }
        releaseSubmit.signal()
        await selection.value
        let turnID = await submission.value

        XCTAssertNil(turnID)
        XCTAssertEqual(store.selectedConversationID, "replacement")
        XCTAssertEqual(lock.withLock { eventReads }, 1)
    }

    func testSuccessfulUploadRestoresExistingRecoveryStatus() async throws {
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL")
        UserDefaults.standard.set("https://recovery-status.test/", forKey: "serverURL")
        defer {
            if let savedServerURL { UserDefaults.standard.set(savedServerURL, forKey: "serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "serverURL") }
        }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                let clipID = request.url!.lastPathComponent
                let body = #"{"clip_id":"\#(clipID)","created":true}"#.data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 201,
                        httpVersion: nil, headerFields: nil
                    )!,
                    body
                )
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                body
            )
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(PendingUploadSpool.phoneDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphanURL = directory.appendingPathComponent(
            "working-recording-\(UUID().uuidString.lowercased()).wav"
        )
        try Data([1, 2, 3]).write(to: orphanURL)
        try Data().write(to: ActiveRecordingFileLease.startedMarkerURL(for: orphanURL))

        let store = AppStore(session: session)
        store.selectedProjectID = "project"
        store.selectedConversationID = "conversation"
        let recording = try makeRecordingForUpload()
        defer {
            store.discardPendingUploads()
            try? FileManager.default.removeItem(at: recording.url)
        }

        store.queueRecording(recording)
        await store.waitForRecordingTasks()

        XCTAssertEqual(store.recoveryItemCount, 1)
        XCTAssertEqual(store.status, "Recording recovery needed")
    }


    func testPendingSpoolPersistsDestinationAndRecordingTime() throws {
        let id = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording-\(id).wav")
        try Data([1, 2, 3]).write(to: url)
        let spool = PendingUploadSpool(directoryURL: directory)
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
        XCTAssertEqual(restored.schemaVersion, PendingClip.currentSchemaVersion)
        XCTAssertEqual(restored.sha256?.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.wavURL(for: restored).path))
    }

    func testPendingSpoolReadsLegacySidecarWithoutSchemaVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "legacy-clip"
        try Data([1, 2, 3]).write(
            to: directory.appendingPathComponent("recording-\(id).wav")
        )
        let legacy: [String: Any] = [
            "id": id,
            "serverURL": "https://example.test/",
            "projectID": "project",
            "conversationID": "conversation",
            "wavFilename": "recording-\(id).wav",
            "durationMs": 900,
            "peakPct": 20,
            "recordedAt": 123,
            "enqueuedAtMs": 456,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(
            to: directory.appendingPathComponent("\(id).json")
        )

        let inventory = PendingUploadSpool(directoryURL: directory).inventory()
        let clip = try XCTUnwrap(inventory.clips.first)
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(clip.schemaVersion, 1)
        XCTAssertNil(clip.sha256)
        XCTAssertTrue(inventory.recoveryItems.isEmpty)
    }

    func testPendingSpoolQuarantinesOverflowingLegacyTimestampWithoutDeletingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "legacy-overflow"
        let audioURL = directory.appendingPathComponent("recording-\(id).wav")
        let metadataURL = directory.appendingPathComponent("\(id).json")
        try Data([1, 2, 3]).write(to: audioURL)
        let legacy: [String: Any] = [
            "id": id,
            "serverURL": "https://example.test/",
            "projectID": "project",
            "conversationID": "conversation",
            "wavFilename": audioURL.lastPathComponent,
            "durationMs": 900,
            "recordedAt": Int.max,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)

        let inventory = PendingUploadSpool(directoryURL: directory).inventory()

        XCTAssertTrue(inventory.clips.isEmpty)
        XCTAssertEqual(inventory.recoveryItems.map(\.reason), [.unreadableMetadata])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testPendingSpoolRejectsVersionTwoSidecarWithoutChecksum() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "missing-checksum"
        let audioURL = directory.appendingPathComponent("recording-\(id).wav")
        try Data([1, 2, 3]).write(to: audioURL)
        let sidecar: [String: Any] = [
            "schemaVersion": 2,
            "id": id,
            "serverURL": "https://example.test/",
            "projectID": "project",
            "conversationID": "conversation",
            "wavFilename": audioURL.lastPathComponent,
            "durationMs": 900,
        ]
        try JSONSerialization.data(withJSONObject: sidecar).write(
            to: directory.appendingPathComponent("\(id).json")
        )

        let inventory = PendingUploadSpool(directoryURL: directory).inventory()
        XCTAssertTrue(inventory.clips.isEmpty)
        XCTAssertEqual(inventory.recoveryItems.map(\.reason), [.unreadableMetadata])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testPendingSpoolCleansPrewarmedRecorderFileThatNeverStarted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent(
            "working-recording-\(UUID().uuidString.lowercased()).wav"
        )
        try Data([1, 2, 3]).write(to: audioURL)
        let spool = PendingUploadSpool(directoryURL: directory)
        var lease: ActiveRecordingFileLease? = ActiveRecordingFileLease(url: audioURL)

        withExtendedLifetime(lease) {
            XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
        }
        lease = nil

        XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testPendingSpoolRecoversStartedRecorderFileAfterLeaseEnds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent(
            "working-recording-\(UUID().uuidString.lowercased()).wav"
        )
        let markerURL = ActiveRecordingFileLease.startedMarkerURL(for: audioURL)
        try Data([1, 2, 3]).write(to: audioURL)
        let spool = PendingUploadSpool(directoryURL: directory)
        var lease: ActiveRecordingFileLease? = ActiveRecordingFileLease(url: audioURL)
        try lease?.markStarted()

        withExtendedLifetime(lease) {
            XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
        }
        lease = nil

        let recovery = try XCTUnwrap(spool.inventory().recoveryItems.first)
        XCTAssertEqual(recovery.reason, .interruptedWorkingFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        try spool.remove(recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testPendingSpoolQuarantinesChecksumMismatchWithoutDeletingRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString.lowercased()
        let audioURL = directory.appendingPathComponent("recording-\(id).wav")
        let metadataURL = directory.appendingPathComponent("\(id).json")
        try Data([1, 2, 3]).write(to: audioURL)
        let spool = PendingUploadSpool(directoryURL: directory)
        let clip = try spool.enqueue(
            recording: LocalRecording(
                id: id, url: audioURL, durationMs: 900, peakPct: 20, recordedAt: 123
            ),
            serverURL: "https://example.test/",
            projectID: "project",
            conversationID: "conversation"
        )

        try spool.quarantine(
            clip,
            reason: .audioChecksumMismatch,
            detail: "The WAV changed after it was queued."
        )
        let inventory = spool.inventory()

        XCTAssertTrue(inventory.clips.isEmpty)
        let recovery = try XCTUnwrap(inventory.recoveryItems.first)
        XCTAssertEqual(recovery.reason, .audioChecksumMismatch)
        XCTAssertEqual(recovery.detail, "The WAV changed after it was queued.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testPendingSpoolCanDiscardAndRecreateUnreadableRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("PendingRecordings", isDirectory: true)
        try Data("not-a-directory".utf8).write(to: directory)
        let spool = PendingUploadSpool(directoryURL: directory)
        let recovery = try XCTUnwrap(spool.inventory().recoveryItems.first)
        XCTAssertEqual(recovery.reason, .unreadableDirectory)

        try spool.remove(recovery)

        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(values.isDirectory, true)
        XCTAssertTrue(spool.inventory().recoveryItems.isEmpty)
    }

    func testPendingSpoolSurfacesOrphanAndCorruptMetadataWithoutDeletingAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanURL = directory.appendingPathComponent("recording-orphan.wav")
        let corruptAudioURL = directory.appendingPathComponent("recording-corrupt.wav")
        let corruptMetadataURL = directory.appendingPathComponent("corrupt.json")
        try Data([1]).write(to: orphanURL)
        try Data([2]).write(to: corruptAudioURL)
        try Data("not-json".utf8).write(to: corruptMetadataURL)

        let inventory = PendingUploadSpool(directoryURL: directory).inventory()
        XCTAssertEqual(
            Set(inventory.recoveryItems.map(\.reason)),
            Set([.missingMetadata, .unreadableMetadata])
        )
        XCTAssertEqual(inventory.protectedCount(for: "https://example.test/"), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptMetadataURL.path))
    }

    func testPendingSpoolKeepsMetadataWhoseAudioIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "missing-audio"
        let metadataURL = directory.appendingPathComponent("\(id).json")
        let sidecar: [String: Any] = [
            "id": id,
            "serverURL": "https://example.test/",
            "projectID": "project",
            "conversationID": "conversation",
            "wavFilename": "recording-\(id).wav",
            "durationMs": 900,
        ]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: metadataURL)

        let inventory = PendingUploadSpool(directoryURL: directory).inventory()
        XCTAssertTrue(inventory.clips.isEmpty)
        XCTAssertEqual(inventory.recoveryItems.map(\.reason), [.metadataWithoutAudio])
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
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

    func preserveForRecovery(holdID: UUID?) {
        log.events.append("capture.preserve")
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
