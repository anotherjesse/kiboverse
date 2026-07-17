import Foundation
import CryptoKit

enum APIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case requestDestinationChanged
    case localRecordingChanged
    case localAttachmentChanged
    case speechGenerationChanged
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid Kibo server URL."
        case .invalidResponse: "The server returned an unreadable response."
        case .requestDestinationChanged: "The selected conversation changed."
        case .localRecordingChanged: "The saved recording changed before it could be uploaded."
        case .localAttachmentChanged: "The saved photo changed before it could be uploaded."
        case .speechGenerationChanged: "The reply audio restarted from a new synthesis."
        case let .server(code, message): message.isEmpty ? "Server error \(code)" : message
        }
    }
}

/// Immutable routing identity for work that may outlive the current UI
/// selection. Retried requests must keep using this value instead of reading
/// mutable store state again.
struct KiboDestination: Sendable, Equatable {
    let serverURL: String
    let projectID: String
    let conversationID: String
}

enum SpeechPCMEncoding: Sendable, Equatable {
    case signed16LittleEndian
}

struct SpeechResponseStream: Sendable {
    let generation: String
    let sampleRate: Int
    let channels: Int
    let encoding: SpeechPCMEncoding
    let chunks: AsyncThrowingStream<Data, Error>

    init(
        generation: String = "test-generation",
        sampleRate: Int,
        channels: Int,
        encoding: SpeechPCMEncoding = .signed16LittleEndian,
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        self.generation = generation
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
        self.chunks = chunks
    }
}

actor KiboAPI {
    private let session: URLSession
    private var baseURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(serverURL: String, session: URLSession = .shared) throws {
        guard let url = Self.normalizedURL(serverURL) else { throw APIError.invalidServerURL }
        self.baseURL = url
        self.session = session
    }

    nonisolated static func canonicalServerURL(_ value: String) -> String? {
        normalizedURL(value)?.absoluteString
    }

    func setServerURL(_ value: String) throws {
        guard let url = Self.normalizedURL(value) else { throw APIError.invalidServerURL }
        baseURL = url
    }

    func projects() async throws -> [KiboProject] {
        try await request(path: ["v1", "projects"], as: ProjectsEnvelope.self).projects
    }

    func conversations(projectID: String) async throws -> [KiboConversation] {
        try await request(path: ["v1", "projects", projectID, "conversations"], as: ConversationsEnvelope.self).conversations
    }

    func events(projectID: String, conversationID: String, after: UInt64 = 0) async throws -> EventsEnvelope {
        try await request(
            path: ["v1", "projects", projectID, "conversations", conversationID, "events"],
            query: [URLQueryItem(name: "after", value: String(after))],
            as: EventsEnvelope.self
        )
    }

    func createProject(name: String) async throws -> KiboProject {
        try await request(
            path: ["v1", "projects"], method: "POST",
            json: CreateNamed(name: name), as: KiboProject.self
        )
    }

    func createConversation(projectID: String, name: String? = nil) async throws -> KiboConversation {
        try await request(
            path: ["v1", "projects", projectID, "conversations"], method: "POST",
            json: CreateConversation(name: name), as: KiboConversation.self
        )
    }

    func uploadClip(
        fileURL: URL, projectID: String, conversationID: String,
        clipID: String, durationMs: Int, peakPct: Int, recordedAt: Int,
        expectedSHA256: String? = nil
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expectedSHA256 == nil || expectedSHA256 == digest else {
            throw APIError.localRecordingChanged
        }
        var request = try makeRequest(path: [
            "v1", "projects", projectID, "conversations", conversationID, "clips", clipID
        ], method: "PUT")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(String(durationMs), forHTTPHeaderField: "X-Duration-Ms")
        request.setValue(String(max(0, min(100, peakPct))), forHTTPHeaderField: "X-Peak-Pct")
        request.setValue(String(recordedAt), forHTTPHeaderField: "X-Recorded-At")
        request.setValue(digest, forHTTPHeaderField: "X-Content-Sha256")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try validate(response: response, data: responseData)
        do {
            let receipt = try decoder.decode(PutClipResponse.self, from: responseData)
            guard receipt.clip_id == clipID else { throw APIError.invalidResponse }
        }
        catch { throw APIError.invalidResponse }
    }

    func uploadImage(
        fileURL: URL, projectID: String, conversationID: String,
        imageID: String, mime: String, width: Int, height: Int,
        recordedAt: Int, caption: String? = nil, expectedSHA256: String
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expectedSHA256 == digest else {
            throw APIError.localAttachmentChanged
        }
        var query: [URLQueryItem] = []
        if let caption, !caption.isEmpty {
            query.append(URLQueryItem(name: "caption", value: caption))
        }
        var request = try makeRequest(
            path: [
                "v1", "projects", projectID, "conversations", conversationID, "images", imageID
            ],
            query: query,
            method: "PUT"
        )
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(digest, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(String(recordedAt), forHTTPHeaderField: "X-Recorded-At")
        request.setValue(String(width), forHTTPHeaderField: "X-Width")
        request.setValue(String(height), forHTTPHeaderField: "X-Height")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try validate(response: response, data: responseData)
        do {
            let receipt = try decoder.decode(PutImageResponse.self, from: responseData)
            guard receipt.image_id == imageID else { throw APIError.invalidResponse }
        }
        catch { throw APIError.invalidResponse }
    }

    func imageContent(projectID: String, conversationID: String, imageID: String) async throws -> Data {
        let request = try makeRequest(path: [
            "v1", "projects", projectID, "conversations", conversationID,
            "images", imageID, "content",
        ])
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func submitTurn(projectID: String, conversationID: String, turnID: String) async throws {
        let _: TurnResponse = try await request(
            path: ["v1", "projects", projectID, "conversations", conversationID, "turns"],
            method: "POST", json: CreateTurn(turn_id: turnID), as: TurnResponse.self
        )
    }

    func retryClip(projectID: String, conversationID: String, clipID: String) async throws {
        try await command(path: [
            "v1", "projects", projectID, "conversations", conversationID,
            "clips", clipID, "retry",
        ])
    }

    func retryTurn(projectID: String, conversationID: String, turnID: String) async throws {
        try await command(path: [
            "v1", "projects", projectID, "conversations", conversationID,
            "turns", turnID, "retry",
        ])
    }

    func speechStream(
        destination: KiboDestination,
        turnID: String,
        fromSample: Int = 0,
        generation: String? = nil
    ) async throws -> SpeechResponseStream {
        guard let requestBaseURL = Self.normalizedURL(destination.serverURL),
              requestBaseURL == baseURL else {
            throw APIError.requestDestinationChanged
        }
        var request = try makeRequest(
            rootURL: requestBaseURL,
            path: [
                "v1", "projects", destination.projectID,
                "conversations", destination.conversationID,
                "turns", turnID, "speech",
            ],
            query: [URLQueryItem(name: "from_sample", value: String(max(0, fromSample)))]
        )
        request.timeoutInterval = 120
        request.networkServiceType = .avStreaming
        request.setValue(
            "application/vnd.kibo.pcm; format=s16le",
            forHTTPHeaderField: "Accept"
        )
        if let generation {
            request.setValue(generation, forHTTPHeaderField: "X-Speech-Generation")
        }
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 412 {
            throw APIError.speechGenerationChanged
        }
        try validate(response: response, data: nil)
        guard let http = response as? HTTPURLResponse,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("application/vnd.kibo.pcm"),
              contentType.contains("format=s16le"),
              let rate = http.value(forHTTPHeaderField: "X-Audio-Sample-Rate").flatMap(Int.init),
              (1...192_000).contains(rate),
              let channels = http.value(forHTTPHeaderField: "X-Audio-Channels").flatMap(Int.init),
              channels == 1 else {
            throw APIError.invalidResponse
        }
        let generation = http.value(forHTTPHeaderField: "X-Speech-Generation")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "legacy"

        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= 4_096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return SpeechResponseStream(
            generation: generation,
            sampleRate: rate,
            channels: channels,
            encoding: .signed16LittleEndian,
            chunks: chunks
        )
    }

    func clipAudio(projectID: String, conversationID: String, clipID: String) async throws -> Data {
        let request = try makeRequest(path: [
            "v1", "projects", projectID, "conversations", conversationID, "clips", clipID, "audio"
        ])
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func request<T: Decodable>(
        path: [String], query: [URLQueryItem] = [], method: String = "GET", as type: T.Type
    ) async throws -> T {
        try await request(path: path, query: query, method: method, body: nil, as: type)
    }

    private func command(path: [String]) async throws {
        let request = try makeRequest(path: path, method: "POST")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func request<Payload: Encodable, T: Decodable>(
        path: [String], query: [URLQueryItem] = [], method: String,
        json: Payload, as type: T.Type
    ) async throws -> T {
        try await request(
            path: path, query: query, method: method,
            body: try encoder.encode(json), as: type
        )
    }

    private func request<T: Decodable>(
        path: [String], query: [URLQueryItem], method: String,
        body: Data?, as type: T.Type
    ) async throws -> T {
        var request = try makeRequest(path: path, query: query, method: method)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func makeRequest(
        rootURL: URL? = nil,
        path: [String],
        query: [URLQueryItem] = [],
        method: String = "GET"
    ) throws -> URLRequest {
        var url = rootURL ?? baseURL
        for component in path { url.append(path: component) }
        if !query.isEmpty {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
            parts.queryItems = query
            // URLComponents leaves "+" bare (it is a legal query character),
            // but the server's form decoding reads a bare "+" as a space —
            // and a caption is fixed at first upload, so that corruption
            // would be permanent. Escape it explicitly; already-encoded
            // octets are untouched because "+" never appears in them.
            parts.percentEncodedQuery = parts.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let queried = parts.url else { throw APIError.invalidServerURL }
            url = queried
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw APIError.server(http.statusCode, message)
        }
    }

    private nonisolated static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              ["http", "https"].contains(parts.scheme?.lowercased()),
              parts.host != nil else { return nil }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = path.isEmpty ? "/" : "/\(path)"
        return parts.url
    }
}
