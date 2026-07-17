import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageNormalizationError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "That file could not be read as an image."
        case .encodingFailed: "The image could not be converted for upload."
        }
    }
}

/// The single value every intake path produces: normalized bytes plus the
/// metadata that travels ONLY as sidecar/header fields. The bytes themselves
/// never carry EXIF/GPS — see `ImageNormalizer`.
struct NormalizedImage: Sendable {
    let data: Data
    let mime: String
    let fileExtension: String
    let width: Int
    let height: Int
    let sha256: String
    /// Epoch seconds of INTAKE — when the user added the image. Deliberately
    /// NOT the EXIF capture date: `recorded_at` orders media within the
    /// conversation (timeline, server claim order, prompt order), so a
    /// years-old library photo must sort where it was ADDED, not where it
    /// was taken. (Camera captures are intake ≈ capture anyway.)
    let recordedAt: Int
}

/// One normalization policy for every image source (app picker, camera, and
/// the share extension):
/// - photographic sources → JPEG q0.8, longest edge ≤ 2048 px;
/// - PNG sources → decode → re-encode as PNG (re-encode is what strips
///   eXIf/tEXt chunks), downscaled only when larger than 2048 px;
/// - HEIC (and anything else) → JPEG;
/// - output BYTES are bounded too: a PNG over the cap loses resolution
///   before it loses its alpha channel (halve pixels while staying PNG);
///   only when even the smallest PNG cannot fit does JPEG take over, and a
///   JPEG encode of an alpha-bearing decode is always composited onto white
///   first — a spooled value must never draw a permanent 400/413, and
///   transparent pixels must never expose whatever RGB sat under them.
/// Decoding uses `CGImageSourceCreateThumbnailAtIndex` for bounded memory
/// (extension-safe) and bakes orientation in. Metadata never survives by
/// construction: the encoder is handed a bare `CGImage` and no property
/// dictionary beyond compression quality.
enum ImageNormalizer {
    static let maxPixelSize = 2048
    static let jpegQuality: Double = 0.8
    /// The server rejects images over 10 MiB; normalize to a safe margin
    /// below it so an accepted intake can never wedge the upload ladder.
    static let maximumUploadBytes = 9_500_000

    static func normalize(data: Data, intakeDate: Date = Date()) throws -> NormalizedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageNormalizationError.unreadableImage
        }
        let sourceIsPNG = CGImageSourceGetType(source)
            .flatMap { UTType($0 as String) }?
            .conforms(to: .png) == true

        var encoded = try encode(source: source, pixelSize: maxPixelSize, asPNG: sourceIsPNG)
        var pixelSize = maxPixelSize
        // Bounded bytes, not just bounded pixels: high-entropy PNG content
        // can exceed the cap at 2048 px. A PNG loses resolution before it
        // loses alpha — halve pixels while staying PNG (privacy holds: the
        // same bare decode is re-encoded, still no metadata).
        while encoded.isPNG, encoded.data.count > maximumUploadBytes, pixelSize > 256 {
            pixelSize /= 2
            encoded = try encode(source: source, pixelSize: pixelSize, asPNG: true)
        }
        if encoded.data.count > maximumUploadBytes {
            // JPEG is unavoidable (a non-PNG source over the cap, or a PNG
            // that could not fit even at the pixel floor). Restart the JPEG
            // ladder at full resolution — JPEG compresses what PNG could
            // not, and `encode` composites any alpha onto white first.
            pixelSize = maxPixelSize
            encoded = try encode(source: source, pixelSize: pixelSize, asPNG: false)
            while encoded.data.count > maximumUploadBytes, pixelSize > 256 {
                pixelSize /= 2
                encoded = try encode(source: source, pixelSize: pixelSize, asPNG: false)
            }
        }
        guard encoded.data.count <= maximumUploadBytes else {
            throw ImageNormalizationError.encodingFailed
        }
        return NormalizedImage(
            data: encoded.data,
            mime: encoded.isPNG ? "image/png" : "image/jpeg",
            fileExtension: encoded.isPNG ? "png" : "jpg",
            width: encoded.width,
            height: encoded.height,
            sha256: SpoolPrimitives.sha256Hex(encoded.data),
            recordedAt: Int(intakeDate.timeIntervalSince1970)
        )
    }

    private struct EncodedImage {
        let data: Data
        let width: Int
        let height: Int
        let isPNG: Bool
    }

    private static func encode(
        source: CGImageSource, pixelSize: Int, asPNG: Bool
    ) throws -> EncodedImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageNormalizationError.unreadableImage
        }
        if !asPNG, hasAlpha(image) {
            // JPEG has no alpha channel: encoding an alpha-bearing decode
            // directly exposes whatever RGB happens to be stored under the
            // transparent pixels (black for premultiplied sources, arbitrary
            // for straight alpha). Composite explicitly onto white so a
            // transparent source degrades predictably.
            guard let composited = compositedOntoWhite(image) else {
                throw ImageNormalizationError.encodingFailed
            }
            image = composited
        }
        let type: UTType = asPNG ? .png : .jpeg
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil
        ) else { throw ImageNormalizationError.encodingFailed }
        let encodeOptions: [CFString: Any] = asPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageNormalizationError.encodingFailed
        }
        if asPNG {
            // FAIL CLOSED: if the encoder's output does not parse as a
            // strictly well-formed PNG, never emit it (it may still carry
            // the eXIf chunk) — re-encode the same decode as JPEG instead.
            guard let stripped = strippingMetadataChunks(fromPNG: encoded as Data) else {
                return try encode(source: source, pixelSize: pixelSize, asPNG: false)
            }
            return EncodedImage(
                data: stripped, width: image.width, height: image.height, isPNG: true
            )
        }
        return EncodedImage(
            data: encoded as Data, width: image.width, height: image.height, isPNG: false
        )
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func compositedOntoWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// ImageIO's PNG encoder injects a minimal eXIf chunk (pixel dimensions
    /// only) even when handed no metadata. Drop every metadata-bearing
    /// ancillary chunk so "no EXIF/GPS/tEXt in the output bytes" holds
    /// byte-for-byte, not just semantically.
    static let droppedPNGChunks: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"]

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Strict, fail-closed PNG chunk walk. Returns nil when the stream is
    /// structurally anomalous in ANY way — bad signature, truncated or
    /// oversized declared chunk length, non-alphabetic chunk type bytes,
    /// a CRC that does not match its chunk's type+payload (checked for every
    /// chunk, including ones this stripper would drop), IHDR that is not
    /// first/unique/13 bytes, missing / non-terminal / non-empty IEND, or
    /// trailing bytes — because bytes this parser has not fully accounted
    /// for must never ship (the caller falls back to a JPEG re-encode, which
    /// preserves the privacy claim while intake still succeeds).
    static func strippingMetadataChunks(fromPNG data: Data) -> Data? {
        let signatureLength = pngSignature.count
        guard data.count > signatureLength,
              [UInt8](data.prefix(signatureLength)) == pngSignature else { return nil }
        var output = data.subdata(in: 0..<signatureLength)
        var index = signatureLength
        var sawTerminalEnd = false
        var chunkOrdinal = 0
        while index < data.count {
            // No chunk may follow IEND, and every chunk needs length + type
            // + CRC even when its payload is empty.
            guard !sawTerminalEnd, index + 12 <= data.count else { return nil }
            let length = data.subdata(in: index..<index + 4).reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 0, length <= data.count - index - 12 else { return nil }
            let typeBytes = [UInt8](data.subdata(in: index + 4..<index + 8))
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
            else { return nil }
            let name = String(bytes: typeBytes, encoding: .ascii) ?? ""
            let chunkEnd = index + 12 + length
            // IHDR must open the stream, appear exactly once, and carry the
            // 13-byte header payload the spec fixes.
            if chunkOrdinal == 0 {
                guard name == "IHDR" else { return nil }
            }
            if name == "IHDR" {
                guard chunkOrdinal == 0, length == 13 else { return nil }
            }
            // Every chunk's CRC must match its type+payload — a stream with
            // even one bad checksum is corrupt end to end, including chunks
            // this stripper would drop.
            let declaredCRC = data.subdata(in: chunkEnd - 4..<chunkEnd)
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard crc32(data[index + 4..<chunkEnd - 4]) == declaredCRC else { return nil }
            if name == "IEND" {
                guard length == 0 else { return nil }
                sawTerminalEnd = true
            }
            if !droppedPNGChunks.contains(name) {
                output.append(data.subdata(in: index..<chunkEnd))
            }
            chunkOrdinal += 1
            index = chunkEnd
        }
        guard sawTerminalEnd, index == data.count else { return nil }
        return output
    }

    /// PNG's CRC-32 (reflected, polynomial 0xEDB88320), table-driven.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = ~0
        bytes.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return ~crc
    }

}
