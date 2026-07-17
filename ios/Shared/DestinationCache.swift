import Foundation

/// The project/conversation list the main app persists into the app-group
/// container so the share extension can offer a destination picker with **no
/// network access**. The main app is the only writer (on every successful
/// project/conversation load and selection change); the extension only reads.
///
/// The cache pins its `serverURL`: a cached destination is only meaningful on
/// the server that produced it, and spooled attachments pin the same URL, so
/// a server switch rebuilds the cache from scratch.
struct DestinationCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Conversation: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    struct Project: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        var conversations: [Conversation]
    }

    /// One pickable destination, resolved for the extension UI.
    struct Destination: Equatable, Sendable, Identifiable, Hashable {
        let serverURL: String
        let projectID: String
        let projectName: String
        let conversationID: String
        let conversationName: String

        var id: String { "\(projectID)/\(conversationID)" }
    }

    let schemaVersion: Int
    var serverURL: String
    var lastSelectedProjectID: String?
    var lastSelectedConversationID: String?
    var projects: [Project]

    init(serverURL: String) {
        schemaVersion = Self.currentSchemaVersion
        self.serverURL = serverURL
        lastSelectedProjectID = nil
        lastSelectedConversationID = nil
        projects = []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serverURL
        case lastSelectedProjectID, lastSelectedConversationID
        case projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported destination-cache schema version \(version)"
            )
        }
        schemaVersion = version
        serverURL = try container.decode(String.self, forKey: .serverURL)
        lastSelectedProjectID = try container.decodeIfPresent(
            String.self, forKey: .lastSelectedProjectID
        )
        lastSelectedConversationID = try container.decodeIfPresent(
            String.self, forKey: .lastSelectedConversationID
        )
        projects = try container.decode([Project].self, forKey: .projects)
    }

    /// Replace the project list while preserving the conversations already
    /// known for projects that survive — the app only ever loads conversations
    /// for the selected project, so the cache accumulates the rest over time.
    mutating func apply(projects loaded: [(id: String, name: String)]) {
        let known = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.conversations) }
        )
        projects = loaded.map {
            Project(id: $0.id, name: $0.name, conversations: known[$0.id] ?? [])
        }
    }

    /// Replace one project's conversation list (a fresh load is authoritative
    /// — it carries renames and deletions). Unknown project IDs are ignored.
    mutating func apply(
        conversations loaded: [(id: String, name: String)], projectID: String
    ) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].conversations = loaded.map {
            Conversation(id: $0.id, name: $0.name)
        }
    }

    mutating func select(projectID: String?, conversationID: String?) {
        lastSelectedProjectID = projectID
        lastSelectedConversationID = conversationID
    }

    /// Every pickable destination, in project order (conversations for
    /// projects the app never visited are simply absent).
    var allDestinations: [Destination] {
        projects.flatMap { project in
            project.conversations.map {
                Destination(
                    serverURL: serverURL,
                    projectID: project.id, projectName: project.name,
                    conversationID: $0.id, conversationName: $0.name
                )
            }
        }
    }

    /// The extension's sensible default: the last conversation the user had
    /// selected in the app, when it still exists; otherwise the first cached
    /// destination; nil when nothing is cached.
    var defaultDestination: Destination? {
        if let projectID = lastSelectedProjectID,
           let conversationID = lastSelectedConversationID,
           let resolved = destination(projectID: projectID, conversationID: conversationID) {
            return resolved
        }
        return allDestinations.first
    }

    func destination(projectID: String, conversationID: String) -> Destination? {
        guard let project = projects.first(where: { $0.id == projectID }),
              let conversation = project.conversations.first(where: { $0.id == conversationID })
        else { return nil }
        return Destination(
            serverURL: serverURL,
            projectID: project.id, projectName: project.name,
            conversationID: conversation.id, conversationName: conversation.name
        )
    }
}

/// Atomic single-file persistence for `DestinationCache`. Reads tolerate a
/// missing or corrupt file (the extension just reports "open Kibo first");
/// writes are best-effort and atomic so the extension can never observe a
/// torn cache.
struct DestinationCacheStore {
    static let filename = "destination-cache.json"

    private let fileURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        fileURL = rootURL.appendingPathComponent(Self.filename)
        self.fileManager = fileManager
    }

    /// The shared store, or nil when the app group container is unavailable
    /// (free-provisioning contingency — there is no extension to feed then).
    static func appGroup(fileManager: FileManager = .default) -> DestinationCacheStore? {
        KiboAppGroup.containerURL(fileManager: fileManager).map {
            DestinationCacheStore(rootURL: $0, fileManager: fileManager)
        }
    }

    func load() -> DestinationCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DestinationCache.self, from: data)
    }

    func save(_ cache: DestinationCache) {
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
