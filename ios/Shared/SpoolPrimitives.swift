import CryptoKit
import Foundation

/// Helpers shared verbatim by the audio and attachment spools. Only code that
/// is byte-for-byte identical between the two belongs here — each spool keeps
/// its own schema, staging, and recovery machinery.
enum SpoolPrimitives {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.contains("/")
            && !filename.contains(":")
    }

    static func isLowercaseHexSHA256(_ digest: String) -> Bool {
        digest.count == 64
            && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
