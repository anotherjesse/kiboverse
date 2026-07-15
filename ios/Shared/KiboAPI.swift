import Foundation
import CryptoKit

enum APIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid Kibo server URL."
        case .invalidResponse: "The server returned an unreadable response."
        case let .server(code, message): message.isEmpty ? "Server error \(code)" : message
        }
    }
}

enum SpeechPCMEncoding: Sendable, Equatable {
    case signed16LittleEndian
}

struct SpeechResponseStream: Sendable {
    let sampleRate: Int
    let channels: Int
    let encoding: SpeechPCMEncoding
    let chunks: AsyncThrowingStream<Data, Error>

    init(
        sampleRate: Int,
        channels: Int,
        encoding: SpeechPCMEncoding = .signed16LittleEndian,
        chunks: AsyncThrowingStream<Data, Error>
    ) {
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
        try await request(path: ["v1", "projects"], method: "POST", json: ["name": name], as: KiboProject.self)
    }

    func createConversation(projectID: String, name: String? = nil) async throws -> KiboConversation {
        try await request(
            path: ["v1", "projects", projectID, "conversations"], method: "POST",
            json: name.map { ["name": $0] } ?? [:], as: KiboConversation.self
        )
    }

    func uploadClip(
        fileURL: URL, projectID: String, conversationID: String,
        clipID: String, durationMs: Int, peakPct: Int, recordedAt: Int
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var request = try makeRequest(path: [
            "v1", "projects", projectID, "conversations", conversationID, "clips", clipID
        ], method: "PUT")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(String(durationMs), forHTTPHeaderField: "X-Duration-Ms")
        request.setValue(String(max(0, min(100, peakPct))), forHTTPHeaderField: "X-Peak-Pct")
        request.setValue(String(recordedAt), forHTTPHeaderField: "X-Recorded-At")
        request.setValue(digest, forHTTPHeaderField: "X-Content-Sha256")
        let (_, response) = try await session.upload(for: request, from: data)
        try validate(response: response, data: nil)
    }

    func submitTurn(projectID: String, conversationID: String, turnID: String) async throws {
        let _: TurnResponse = try await request(
            path: ["v1", "projects", projectID, "conversations", conversationID, "turns"],
            method: "POST", json: ["turn_id": turnID], as: TurnResponse.self
        )
    }

    func speechStream(
        projectID: String,
        conversationID: String,
        turnID: String,
        fromSample: Int = 0
    ) async throws -> SpeechResponseStream {
        var request = try makeRequest(
            path: [
                "v1", "projects", projectID, "conversations", conversationID,
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
        let (bytes, response) = try await session.bytes(for: request)
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
        path: [String], query: [URLQueryItem] = [], method: String = "GET",
        json: [String: String]? = nil, as type: T.Type
    ) async throws -> T {
        var request = try makeRequest(path: path, query: query, method: method)
        if let json {
            request.httpBody = try encoder.encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func makeRequest(path: [String], query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        var url = baseURL
        for component in path { url.append(path: component) }
        if !query.isEmpty {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
            parts.queryItems = query
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

private struct TurnResponse: Codable {
    let turnId: String
    enum CodingKeys: String, CodingKey { case turnId = "turn_id" }
}
