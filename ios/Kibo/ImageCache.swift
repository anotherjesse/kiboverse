import UIKit

/// Content-addressed cache for conversation images: decoded images in memory
/// (NSCache, bounded by decoded-pixel cost) over verified bytes on disk,
/// keyed by the journal event's sha256. Entries are immutable forever. A
/// downloaded payload is hashed against the event digest BEFORE it is cached
/// or returned — a mismatch is rejected and nothing is stored, so a corrupt
/// response can never poison the cache.
///
/// Disk entries deliberately have NO LRU/eviction: immutable-forever mirrors
/// the server's content-addressed contract, and at this scale (personal
/// conversations, ≤2048 px normalized images) the Caches directory — which
/// the OS may purge wholesale anyway — is the right boundary.
actor ConversationImageCache {
    enum CacheError: Error {
        case checksumMismatch
        case undecodableImage
    }

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let memory = NSCache<NSString, UIImage>()
    /// One load per digest: concurrent requests for the same image await a
    /// single in-flight task instead of racing duplicate downloads/decodes.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    init(directoryURL: URL? = nil, memoryLimitBytes: Int = 128 * 1024 * 1024) {
        self.directoryURL = directoryURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ConversationImages", isDirectory: true)
        memory.totalCostLimit = memoryLimitBytes
        try? FileManager.default.createDirectory(
            at: self.directoryURL, withIntermediateDirectories: true
        )
    }

    func image(
        sha256: String, fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> UIImage {
        if let cached = memory.object(forKey: sha256 as NSString) { return cached }
        if let running = inFlight[sha256] { return try await running.value }
        let task = Task { try await self.loadAndCache(sha256: sha256, fetch: fetch) }
        inFlight[sha256] = task
        defer { inFlight[sha256] = nil }
        return try await task.value
    }

    private func loadAndCache(
        sha256: String, fetch: () async throws -> Data
    ) async throws -> UIImage {
        let fileURL = directoryURL.appendingPathComponent(sha256)
        if let data = try? Data(contentsOf: fileURL),
           SpoolPrimitives.sha256Hex(data) == sha256,
           let image = UIImage(data: data) {
            store(image, sha256: sha256)
            return image
        }

        let data = try await fetch()
        guard SpoolPrimitives.sha256Hex(data) == sha256 else {
            throw CacheError.checksumMismatch
        }
        guard let image = UIImage(data: data) else {
            throw CacheError.undecodableImage
        }
        try? data.write(to: fileURL, options: .atomic)
        store(image, sha256: sha256)
        return image
    }

    /// NSCache cost = decoded bitmap footprint, which is what actually
    /// occupies memory (the encoded byte count would undercount ~10×).
    private func store(_ image: UIImage, sha256: String) {
        let cost: Int
        if let cg = image.cgImage {
            cost = cg.bytesPerRow * cg.height
        } else {
            cost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        }
        memory.setObject(image, forKey: sha256 as NSString, cost: cost)
    }
}
