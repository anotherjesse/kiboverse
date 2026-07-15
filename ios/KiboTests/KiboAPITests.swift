import XCTest
@testable import Kibo

@MainActor
final class KiboAPITests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testListsProjectsAndUsesVersionedPath() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/projects")
            let body = #"{"projects":[{"id":"kibo","name":"Kibo","created_at":1}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let api = try KiboAPI(serverURL: "http://example.test")
        let projects = try await api.projects()
        XCTAssertEqual(projects.first?.name, "Kibo")
    }

    func testBasePathAndTrailingSlashArePreserved() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/kibo/v1/projects")
            let body = #"{"projects":[]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let api = try KiboAPI(serverURL: "https://example.test/gateway/kibo/")
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
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 44).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let api = try KiboAPI(serverURL: "https://example.test")
        try await api.uploadClip(
            fileURL: url, projectID: "p", conversationID: "c", clipID: "clip-1",
            durationMs: 875, peakPct: 42, recordedAt: 1234
        )
    }

    func testTimelineBuildsPersonAndReplyCards() throws {
        let data = #"[{"seq":1,"kind":"clip","id":"c1"},{"seq":2,"kind":"transcript","clip":"c1","text":"Hello"},{"seq":3,"kind":"turn","id":"t1","clips":["c1"]},{"seq":4,"kind":"reply","turn":"t1","text":"Hi","audio":"tts/t1.wav"}]"#.data(using: .utf8)!
        let events = try JSONDecoder().decode([KiboEvent].self, from: data)
        XCTAssertEqual(events.timeline().map(\.body), ["Hello", "Hi"])
        XCTAssertTrue(events.timeline().last?.canPlay == true)
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

    func testPCMWrapperCreatesWAVHeader() {
        let wav = SpeechPlayer.wav(pcm: Data([0, 0, 1, 0]), sampleRate: 24_000)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(wav.count, 48)
    }

    func testReplyResumeRewindsOneSecondWithoutGoingNegative() {
        XCTAssertEqual(SpeechPlayer.rewoundTime(8.4), 7.4, accuracy: 0.001)
        XCTAssertEqual(SpeechPlayer.rewoundTime(0.4), 0, accuracy: 0.001)
    }

    func testEveryRecordingInterruptionCreatesFreshPlaybackEngine() throws {
        var players: [FakeSpeechAudioPlayer] = []
        var sessionResets: [Bool] = []
        let speech = SpeechPlayer(
            makePlayer: { _ in
                let player = FakeSpeechAudioPlayer()
                players.append(player)
                return player
            },
            activateSession: { sessionResets.append($0) }
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
        XCTAssertEqual(sessionResets, [false, true, true])
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
                lock.lock()
                activeUploads += 1
                maximumActiveUploads = max(maximumActiveUploads, activeUploads)
                uploadedIDs.append(request.url!.lastPathComponent)
                let isFirst = uploadedIDs.count == 1
                lock.unlock()
                if isFirst {
                    firstUploadStarted.fulfill()
                    _ = releaseFirstUpload.wait(timeout: .now() + 2)
                }
                lock.lock()
                activeUploads -= 1
                lock.unlock()
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = #"{"events":[],"latest_seq":0}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let store = AppStore()
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
        lock.lock()
        let finalMaximum = maximumActiveUploads
        let finalIDs = uploadedIDs
        lock.unlock()
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
            KiboProject(id: "first", name: "First", createdAt: 1),
            KiboProject(id: "remembered", name: "Remembered", createdAt: 2),
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
}

@MainActor
private final class FakeSpeechAudioPlayer: SpeechAudioPlaying {
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var didFinish: (() -> Void)?
    private(set) var playCount = 0
    private(set) var wasStopped = false

    func prepareToPlay() {}
    func play() -> Bool {
        playCount += 1
        isPlaying = true
        return true
    }
    func stop() {
        wasStopped = true
        isPlaying = false
    }
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
