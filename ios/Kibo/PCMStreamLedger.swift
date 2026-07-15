import Foundation

/// Append-only decoded speech. All positions are mono sample frames.
struct PCMStreamLedger: Sendable {
    private(set) var samples: [Int16] = []
    private var orphanedByte: UInt8?

    var receivedSample: Int { samples.count }
    var hasPartialSample: Bool { orphanedByte != nil }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var index = data.startIndex
        if let low = orphanedByte {
            samples.append(Int16(bitPattern: UInt16(low) | UInt16(data[index]) << 8))
            orphanedByte = nil
            index = data.index(after: index)
        }
        while index < data.endIndex {
            let next = data.index(after: index)
            guard next < data.endIndex else {
                orphanedByte = data[index]
                break
            }
            samples.append(Int16(bitPattern: UInt16(data[index]) | UInt16(data[next]) << 8))
            index = data.index(after: next)
        }
    }

    /// A resumed response starts at a sample boundary, so an incomplete byte
    /// from the failed response must not be combined with the retried sample.
    mutating func discardPartialSample() {
        orphanedByte = nil
    }

    func chunk(from start: Int, maximumCount: Int) -> [Int16] {
        guard start >= 0, maximumCount > 0, start < samples.count else { return [] }
        let end = min(samples.count, start + maximumCount)
        return Array(samples[start..<end])
    }
}
