import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Kibo

/// Proves the normalization privacy contract: EXIF/GPS/tEXt metadata never
/// survives into the normalized bytes — by construction, not by filtering.
final class ImageNormalizerTests: XCTestCase {
    func testPhotographicSourceBecomesBoundedJPEGWithoutCaptureMetadata() throws {
        let source = try makeFixture(
            type: .jpeg, width: 3000, height: 2000,
            gps: true, dateOriginal: "2024:03:05 10:30:00", cameraMakeModel: true
        )
        XCTAssertNotNil(properties(of: source)[kCGImagePropertyGPSDictionary])

        let intake = Date(timeIntervalSince1970: 1_800_000_000)
        let normalized = try ImageNormalizer.normalize(data: source, intakeDate: intake)

        XCTAssertEqual(normalized.mime, "image/jpeg")
        XCTAssertEqual(normalized.fileExtension, "jpg")
        XCTAssertEqual(max(normalized.width, normalized.height), 2048)
        XCTAssertEqual(
            Double(normalized.width) / Double(normalized.height), 1.5, accuracy: 0.01
        )
        assertNoCaptureMetadata(in: normalized.data)
        XCTAssertEqual(normalized.sha256, SpoolPrimitives.sha256Hex(normalized.data))
        XCTAssertEqual(normalized.recordedAt, 1_800_000_000)
    }

    func testSmallSourceIsNeverUpscaled() throws {
        let source = try makeFixture(type: .jpeg, width: 640, height: 480)
        let normalized = try ImageNormalizer.normalize(data: source)
        XCTAssertEqual(normalized.width, 640)
        XCTAssertEqual(normalized.height, 480)
    }

    /// `recorded_at` orders media within the conversation, so it is ALWAYS
    /// intake time — a years-old library photo must sort where it was added,
    /// never leap to where it was taken.
    func testRecordedAtIsAlwaysIntakeTimeEvenWithAnEXIFCaptureDate() throws {
        let intake = Date(timeIntervalSince1970: 1_700_000_000)
        let ancient = try makeFixture(
            type: .jpeg, width: 64, height: 64, dateOriginal: "2019:01:01 00:00:00"
        )
        XCTAssertEqual(
            try ImageNormalizer.normalize(data: ancient, intakeDate: intake).recordedAt,
            1_700_000_000
        )
        let dateless = try makeFixture(type: .jpeg, width: 64, height: 64)
        XCTAssertEqual(
            try ImageNormalizer.normalize(data: dateless, intakeDate: intake).recordedAt,
            1_700_000_000
        )
    }

    func testPNGIsAlwaysReencodedAsPNGDroppingTextChunks() throws {
        let source = try makeFixture(
            type: .png, width: 800, height: 600,
            dateOriginal: "2024:03:05 10:30:00", pngText: true
        )
        // The fixture must actually carry droppable metadata for this test to
        // prove anything.
        XCTAssertTrue(
            containsAnyChunkMarker(source),
            "PNG fixture should contain tEXt/iTXt/eXIf chunks"
        )

        let normalized = try ImageNormalizer.normalize(data: source)

        XCTAssertEqual(normalized.mime, "image/png")
        XCTAssertEqual(normalized.fileExtension, "png")
        XCTAssertEqual(normalized.width, 800)
        XCTAssertEqual(normalized.height, 600)
        XCTAssertFalse(
            containsAnyChunkMarker(normalized.data),
            "Normalized PNG bytes must contain no tEXt/iTXt/zTXt/eXIf chunks"
        )
        assertNoCaptureMetadata(in: normalized.data)
        // The chunk-stripped file must still be a fully decodable PNG.
        let decoded = properties(of: normalized.data)
        XCTAssertEqual(decoded[kCGImagePropertyPixelWidth] as? Int, 800)
        XCTAssertEqual(decoded[kCGImagePropertyPixelHeight] as? Int, 600)
    }

    func testOversizePNGIsDownscaledButStaysPNG() throws {
        let source = try makeFixture(type: .png, width: 3000, height: 1000)
        let normalized = try ImageNormalizer.normalize(data: source)
        XCTAssertEqual(normalized.mime, "image/png")
        XCTAssertEqual(max(normalized.width, normalized.height), 2048)
    }

    func testHEICSourceIsTranscodedToJPEG() throws {
        let source: Data
        do {
            source = try makeFixture(
                type: .heic, width: 1200, height: 900,
                gps: true, dateOriginal: "2023:12:24 08:15:00"
            )
        } catch FixtureError.encoderUnavailable {
            throw XCTSkip("This simulator cannot encode HEIC fixtures")
        }

        let normalized = try ImageNormalizer.normalize(data: source)

        XCTAssertEqual(normalized.mime, "image/jpeg")
        XCTAssertEqual(normalized.width, 1200)
        XCTAssertEqual(normalized.height, 900)
        assertNoCaptureMetadata(in: normalized.data)
    }

    func testOrientationIsBakedIntoPixels() throws {
        // Orientation 6 = 90° CW: stored 320x200, display 200x320.
        let source = try makeFixture(type: .jpeg, width: 320, height: 200, orientation: 6)
        let normalized = try ImageNormalizer.normalize(data: source)
        XCTAssertEqual(normalized.width, 200)
        XCTAssertEqual(normalized.height, 320)
        let orientation = properties(of: normalized.data)[kCGImagePropertyOrientation] as? UInt32
        XCTAssertTrue(orientation == nil || orientation == 1)
    }

    func testNonImageDataIsRejected() {
        XCTAssertThrowsError(try ImageNormalizer.normalize(data: Data("not an image".utf8)))
    }

    // MARK: - Bounded output bytes

    func testHighEntropyPNGDownscalesAndStaysPNGUnderTheUploadCap() throws {
        // Random noise is incompressible: a 2048² noise PNG exceeds the
        // server's per-image cap even at bounded pixels. A PNG loses
        // resolution before it loses its format (and with it, alpha): the
        // normalizer halves pixels while staying PNG rather than spooling an
        // un-uploadable value or transcoding to JPEG.
        let source = try noisePNGFixture(size: 2048)
        XCTAssertGreaterThan(
            source.count, ImageNormalizer.maximumUploadBytes,
            "Fixture must exceed the cap for this test to prove anything"
        )

        let normalized = try ImageNormalizer.normalize(data: source)

        XCTAssertEqual(normalized.mime, "image/png")
        XCTAssertLessThanOrEqual(normalized.data.count, ImageNormalizer.maximumUploadBytes)
        XCTAssertLessThan(
            max(normalized.width, normalized.height), 2048,
            "The byte cap is met by trading resolution, not format"
        )
    }

    func testOversizeTransparentPNGKeepsAlphaByDownscalingInsteadOfJPEG() throws {
        // A transparent high-entropy PNG over the cap: the left half is
        // fully transparent with arbitrary RGB noise stored underneath.
        // Falling back to JPEG would drop alpha and expose that noise; the
        // normalizer must stay PNG (downscaled) with transparency intact.
        let source = try noisePNGFixture(size: 2048, transparentLeftHalf: true)
        XCTAssertGreaterThan(
            source.count, ImageNormalizer.maximumUploadBytes,
            "Fixture must exceed the cap for this test to prove anything"
        )

        let normalized = try ImageNormalizer.normalize(data: source)

        XCTAssertEqual(normalized.mime, "image/png", "Alpha survives only as PNG")
        XCTAssertLessThanOrEqual(normalized.data.count, ImageNormalizer.maximumUploadBytes)
        let pixel = try rgbaPixel(
            in: normalized.data,
            atNormalizedX: 0.25, y: 0.5
        )
        XCTAssertEqual(
            pixel.alpha, 0,
            "Transparent pixels stay transparent — the RGB stored under them never becomes visible"
        )
    }

    func testTransparentNonPNGSourceCompositesOntoWhiteInJPEGOutput() throws {
        // Non-PNG sources always become JPEG, which has no alpha channel: an
        // uncomposited encode exposes whatever RGB sits under transparent
        // pixels (black for a premultiplied decode). The normalizer must
        // composite onto white explicitly.
        let source: Data
        do {
            source = try transparentGIFFixture(size: 256)
        } catch FixtureError.encoderUnavailable {
            throw XCTSkip("This simulator cannot encode GIF fixtures")
        }

        let normalized = try ImageNormalizer.normalize(data: source)

        XCTAssertEqual(normalized.mime, "image/jpeg")
        let transparentRegion = try rgbaPixel(in: normalized.data, atNormalizedX: 0.25, y: 0.5)
        XCTAssertGreaterThan(transparentRegion.red, 200, "Transparent pixels composite to white")
        XCTAssertGreaterThan(transparentRegion.green, 200, "Transparent pixels composite to white")
        XCTAssertGreaterThan(transparentRegion.blue, 200, "Transparent pixels composite to white")
        let opaqueRegion = try rgbaPixel(in: normalized.data, atNormalizedX: 0.75, y: 0.5)
        XCTAssertGreaterThan(
            opaqueRegion.blue, Int(opaqueRegion.red) + 60,
            "Opaque pixels keep their own color"
        )
    }

    // MARK: - Fail-closed PNG chunk stripping

    func testStripperRemovesEveryMetadataChunkTypeAndKeepsCriticalChunks() throws {
        var stream = pngSignature
        stream.append(pngChunk("IHDR", payload: Data(count: 13)))
        for name in ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"] {
            stream.append(pngChunk(name, payload: Data("secret".utf8)))
        }
        stream.append(pngChunk("IDAT", payload: Data([1, 2, 3])))
        stream.append(pngChunk("IEND"))

        let stripped = try XCTUnwrap(ImageNormalizer.strippingMetadataChunks(fromPNG: stream))

        for name in ImageNormalizer.droppedPNGChunks {
            XCTAssertNil(
                stripped.range(of: Data(name.utf8)),
                "\(name) must be stripped from the output bytes"
            )
        }
        for name in ["IHDR", "IDAT", "IEND"] {
            XCTAssertNotNil(
                stripped.range(of: Data(name.utf8)),
                "\(name) must survive stripping"
            )
        }
        XCTAssertNil(stripped.range(of: Data("secret".utf8)))
    }

    func testStripperFailsClosedOnEveryStructuralAnomaly() {
        var valid = pngSignature
        valid.append(pngChunk("IHDR", payload: Data(count: 13)))
        valid.append(pngChunk("IDAT", payload: Data([1, 2, 3])))
        valid.append(pngChunk("IEND"))
        XCTAssertNotNil(ImageNormalizer.strippingMetadataChunks(fromPNG: valid))

        // Wrong signature.
        var badSignature = valid
        badSignature[0] = 0x00
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: badSignature))

        // Truncated mid-chunk.
        XCTAssertNil(
            ImageNormalizer.strippingMetadataChunks(fromPNG: valid.dropLast(4))
        )

        // Declared length overruns the stream.
        var oversized = pngSignature
        oversized.append(pngChunk("IHDR", payload: Data(count: 13)))
        oversized.append(Data([0x00, 0xFF, 0xFF, 0xFF]))
        oversized.append(Data("IDAT".utf8))
        oversized.append(Data([1, 2, 3, 4]))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: oversized))

        // A stream that simply ends at EOF without IEND is not accepted.
        var missingEnd = pngSignature
        missingEnd.append(pngChunk("IHDR", payload: Data(count: 13)))
        missingEnd.append(pngChunk("IDAT", payload: Data([1, 2, 3])))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: missingEnd))

        // Trailing bytes after IEND.
        var trailing = valid
        trailing.append(Data([0xDE, 0xAD, 0xBE]))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: trailing))

        // A chunk after IEND (including a second IEND) is anomalous.
        var afterEnd = valid
        afterEnd.append(pngChunk("IDAT", payload: Data([9])))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: afterEnd))

        // Chunk type bytes must be ASCII letters.
        var badType = pngSignature
        badType.append(pngChunk("IHDR", payload: Data(count: 13)))
        badType.append(pngChunk("0BAD", payload: Data([1])))
        badType.append(pngChunk("IEND"))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: badType))

        // IEND must be empty.
        var fatEnd = pngSignature
        fatEnd.append(pngChunk("IHDR", payload: Data(count: 13)))
        fatEnd.append(pngChunk("IDAT", payload: Data([1])))
        fatEnd.append(pngChunk("IEND", payload: Data([1])))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: fatEnd))
    }

    func testStripperRejectsAnyCorruptChunkCRC() throws {
        // The baseline stream (real CRCs throughout) must pass: it carries a
        // critical chunk (IDAT), a retained ancillary chunk (sRGB), and a
        // stripped chunk (tEXt).
        func stream(
            ihdr: Data? = nil, srgb: Data? = nil, text: Data? = nil,
            idat: Data? = nil, iend: Data? = nil
        ) -> Data {
            var stream = pngSignature
            stream.append(ihdr ?? pngChunk("IHDR", payload: Data(count: 13)))
            stream.append(srgb ?? pngChunk("sRGB", payload: Data([0])))
            stream.append(text ?? pngChunk("tEXt", payload: Data("secret".utf8)))
            stream.append(idat ?? pngChunk("IDAT", payload: Data([1, 2, 3])))
            stream.append(iend ?? pngChunk("IEND"))
            return stream
        }
        let baseline = try XCTUnwrap(
            ImageNormalizer.strippingMetadataChunks(fromPNG: stream()),
            "A fully valid stream must strip cleanly"
        )
        XCTAssertNil(baseline.range(of: Data("tEXt".utf8)))
        XCTAssertNotNil(baseline.range(of: Data("sRGB".utf8)))

        // A corrupt CRC on a critical chunk fails closed.
        XCTAssertNil(
            ImageNormalizer.strippingMetadataChunks(
                fromPNG: stream(idat: corruptingCRC(of: pngChunk("IDAT", payload: Data([1, 2, 3]))))
            ),
            "Corrupt IDAT CRC must be rejected"
        )
        // A corrupt CRC on a retained ancillary chunk fails closed — the
        // chunk would be copied into the output, so its bytes must verify.
        XCTAssertNil(
            ImageNormalizer.strippingMetadataChunks(
                fromPNG: stream(srgb: corruptingCRC(of: pngChunk("sRGB", payload: Data([0]))))
            ),
            "Corrupt sRGB CRC must be rejected"
        )
        // A corrupt CRC on a chunk the stripper would DROP still fails
        // closed: one bad checksum means the stream is corrupt end to end.
        XCTAssertNil(
            ImageNormalizer.strippingMetadataChunks(
                fromPNG: stream(text: corruptingCRC(of: pngChunk("tEXt", payload: Data("secret".utf8))))
            ),
            "Corrupt tEXt CRC must be rejected even though tEXt is stripped"
        )
    }

    func testStripperEnforcesIHDRFirstUniqueAndThirteenBytes() {
        // IHDR must open the stream.
        var ihdrSecond = pngSignature
        ihdrSecond.append(pngChunk("IDAT", payload: Data([1])))
        ihdrSecond.append(pngChunk("IHDR", payload: Data(count: 13)))
        ihdrSecond.append(pngChunk("IEND"))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: ihdrSecond))

        // IHDR must be unique.
        var doubleHeader = pngSignature
        doubleHeader.append(pngChunk("IHDR", payload: Data(count: 13)))
        doubleHeader.append(pngChunk("IHDR", payload: Data(count: 13)))
        doubleHeader.append(pngChunk("IDAT", payload: Data([1])))
        doubleHeader.append(pngChunk("IEND"))
        XCTAssertNil(ImageNormalizer.strippingMetadataChunks(fromPNG: doubleHeader))

        // IHDR's payload is fixed at 13 bytes by the spec.
        for badLength in [12, 14] {
            var wrongSize = pngSignature
            wrongSize.append(pngChunk("IHDR", payload: Data(count: badLength)))
            wrongSize.append(pngChunk("IDAT", payload: Data([1])))
            wrongSize.append(pngChunk("IEND"))
            XCTAssertNil(
                ImageNormalizer.strippingMetadataChunks(fromPNG: wrongSize),
                "A \(badLength)-byte IHDR must be rejected"
            )
        }
    }

    // MARK: - Fixtures

    private enum FixtureError: Error {
        case encoderUnavailable
        case drawingFailed
    }

    private func makeFixture(
        type: UTType,
        width: Int,
        height: Int,
        gps: Bool = false,
        dateOriginal: String? = nil,
        cameraMakeModel: Bool = false,
        orientation: Int? = nil,
        pngText: Bool = false
    ) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FixtureError.drawingFailed }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw FixtureError.drawingFailed }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil
        ) else { throw FixtureError.encoderUnavailable }

        var metadata: [CFString: Any] = [:]
        if gps {
            metadata[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        if let dateOriginal {
            metadata[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateOriginal,
                kCGImagePropertyExifDateTimeDigitized: dateOriginal,
            ]
        }
        if cameraMakeModel {
            metadata[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "TestCam",
                kCGImagePropertyTIFFModel: "UnitTest 3000",
            ]
        }
        if let orientation {
            metadata[kCGImagePropertyOrientation] = orientation
        }
        if pngText {
            metadata[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGAuthor: "A Person",
                kCGImagePropertyPNGDescription: "Sensitive description text",
                kCGImagePropertyPNGSoftware: "FixtureMaker",
            ]
        }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encoderUnavailable
        }
        return encoded as Data
    }

    private var pngSignature: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// A raw PNG chunk carrying a REAL CRC over type+payload — the stripper
    /// validates checksums, so a fixture with a fake CRC would prove the
    /// opposite of what these tests claim.
    private func pngChunk(_ name: String, payload: Data = Data()) -> Data {
        var chunk = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
        chunk.append(Data(name.utf8))
        chunk.append(payload)
        var crc = UInt32(pngCRC(Data(name.utf8) + payload)).bigEndian
        withUnsafeBytes(of: &crc) { chunk.append(contentsOf: $0) }
        return chunk
    }

    /// Independent bitwise CRC-32 (reflected, poly 0xEDB88320) so the
    /// fixtures do not certify the production table-driven implementation
    /// with itself.
    private func pngCRC(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The same chunk with its stored CRC corrupted (last CRC byte flipped).
    private func corruptingCRC(of chunk: Data) -> Data {
        var corrupted = chunk
        corrupted[corrupted.count - 1] ^= 0xFF
        return corrupted
    }

    /// Incompressible 32-bit noise, encoded as a real PNG. With
    /// `transparentLeftHalf` the left half's alpha is forced to zero while
    /// its RGB noise stays in place (straight alpha) — the exact shape whose
    /// hidden RGB a JPEG fallback would expose.
    private func noisePNGFixture(size: Int, transparentLeftHalf: Bool = false) throws -> Data {
        let bytesPerRow = size * 4
        var raw = Data(count: bytesPerRow * size)
        raw.withUnsafeMutableBytes { buffer in
            var generator = SystemRandomNumberGenerator()
            let words = buffer.bindMemory(to: UInt64.self)
            for index in words.indices { words[index] = generator.next() }
            guard transparentLeftHalf else { return }
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<(size / 2) {
                    bytes[(y * size + x) * 4 + 3] = 0
                }
            }
        }
        let alphaInfo: CGImageAlphaInfo = transparentLeftHalf ? .last : .noneSkipLast
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(
                  width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { throw FixtureError.drawingFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else { throw FixtureError.encoderUnavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encoderUnavailable
        }
        return encoded as Data
    }

    /// A GIF whose left half is transparent (over red RGB) and right half is
    /// opaque blue — the smallest real intake shape that forces the
    /// JPEG-with-alpha encode path.
    private func transparentGIFFixture(size: Int) throws -> Data {
        let bytesPerRow = size * 4
        var raw = Data(count: bytesPerRow * size)
        raw.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<size {
                    let offset = (y * size + x) * 4
                    if x < size / 2 {
                        bytes[offset] = 255      // red under a transparent pixel
                        bytes[offset + 3] = 0
                    } else {
                        bytes[offset + 2] = 255  // opaque blue
                        bytes[offset + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(
                  width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { throw FixtureError.drawingFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.gif.identifier as CFString, 1, nil
        ) else { throw FixtureError.encoderUnavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encoderUnavailable
        }
        return encoded as Data
    }

    /// Decodes normalized output bytes and samples one pixel (normalized
    /// coordinates) as straight RGBA.
    private func rgbaPixel(
        in data: Data, atNormalizedX x: Double, y: Double
    ) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.drawingFailed
        }
        let width = image.width
        let height = image.height
        var raw = Data(count: width * height * 4)
        try raw.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw FixtureError.drawingFailed }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let pixelX = min(width - 1, max(0, Int(Double(width) * x)))
        let pixelY = min(height - 1, max(0, Int(Double(height) * y)))
        let offset = (pixelY * width + pixelX) * 4
        return (
            red: Int(raw[offset]),
            green: Int(raw[offset + 1]),
            blue: Int(raw[offset + 2]),
            alpha: Int(raw[offset + 3])
        )
    }

    private func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return [:] }
        return properties
    }

    /// The privacy claim: no GPS, no capture timestamps, no camera identity.
    private func assertNoCaptureMetadata(
        in data: Data, file: StaticString = #filePath, line: UInt = #line
    ) {
        let properties = properties(of: data)
        XCTAssertNil(
            properties[kCGImagePropertyGPSDictionary],
            "GPS metadata must never survive normalization", file: file, line: line
        )
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal], file: file, line: line)
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeDigitized], file: file, line: line)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake], file: file, line: line)
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel], file: file, line: line)
        XCTAssertNil(tiff[kCGImagePropertyTIFFDateTime], file: file, line: line)
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(png[kCGImagePropertyPNGAuthor], file: file, line: line)
        XCTAssertNil(png[kCGImagePropertyPNGDescription], file: file, line: line)
    }

    private func containsAnyChunkMarker(_ data: Data) -> Bool {
        for marker in ["tEXt", "iTXt", "zTXt", "eXIf"] {
            if data.range(of: Data(marker.utf8)) != nil { return true }
        }
        return false
    }
}
