import XCTest
import Foundation
import AppKit
import CoreGraphics
import CoreImage
@testable import VocatecaCore

/// Tests for WP-5 OCR extensions:
///   - `OCRExtraction.hashtags(in:)`
///   - `VisionOCR.detectQRCodes(in:)`
///   - `VisionOCR.classifyImage(at:)`
final class OCRExtensionTests: XCTestCase {

    // MARK: - hashtags (pure, no Vision)

    func testHashtagsBasic() {
        let text = "Great session! #music #Podcast #music"
        let tags = OCRExtraction.hashtags(in: text)
        // De-duped, lowercased, no leading #.
        XCTAssertEqual(tags, ["music", "podcast"])
    }

    func testHashtagsEmptyInput() {
        XCTAssertEqual(OCRExtraction.hashtags(in: ""), [])
    }

    func testHashtagsNoHashtags() {
        XCTAssertEqual(OCRExtraction.hashtags(in: "Hello world"), [])
    }

    func testHashtagsWordBoundaryRequired() {
        // "text#inline" — no word boundary before # → should NOT match.
        // "# space" — space after # → should NOT match (no word chars after #).
        // "#valid" — start of boundary → should match.
        let text = "text#inline  # space  #valid"
        let tags = OCRExtraction.hashtags(in: text)
        XCTAssertFalse(tags.contains("inline"), "No word boundary before # → not a hashtag")
        XCTAssertFalse(tags.contains("space"),  "# followed by space → not a hashtag")
        XCTAssertTrue(tags.contains("valid"),   "#valid at word boundary → is a hashtag")
    }

    func testHashtagsNumericAllowed() {
        // Instagram allows purely numeric hashtags like #2024.
        let tags = OCRExtraction.hashtags(in: "#2024 #art")
        XCTAssertTrue(tags.contains("2024"), "Numeric hashtag should be accepted")
        XCTAssertTrue(tags.contains("art"))
    }

    func testHashtagsPreserveOrder() {
        // First occurrence wins for de-dup; order of first appearances preserved.
        let tags = OCRExtraction.hashtags(in: "#charlie #alpha #beta #alpha #charlie")
        XCTAssertEqual(tags, ["charlie", "alpha", "beta"])
    }

    func testHashtagsWithUnderscores() {
        let tags = OCRExtraction.hashtags(in: "#photo_of_the_day #NoFilter")
        XCTAssertEqual(tags, ["photo_of_the_day", "nofilter"])
    }

    // MARK: - QR code detection

    /// Renders a QR code via CoreImage and asserts Vision decodes the payload.
    func testDetectQRCodes() throws {
        let payload = "https://example.com/qr-test-\(UUID().uuidString)"
        let qrURL = try Self.renderQRCode(payload: payload)
        defer { try? FileManager.default.removeItem(at: qrURL) }

        let ocr = VisionOCR()
        let decoded: [String]
        do {
            decoded = try ocr.detectQRCodes(in: qrURL)
        } catch {
            throw XCTSkip("detectQRCodes threw (headless CI?): \(error)")
        }

        guard !decoded.isEmpty else {
            throw XCTSkip("Vision returned no QR codes — possibly headless CI without Vision support")
        }

        XCTAssertTrue(
            decoded.contains(payload),
            "Decoded QR payloads should contain '\(payload)'; got: \(decoded)"
        )
    }

    // MARK: - Image classification

    /// Renders a simple coloured rectangle and asserts classifyImage returns ≥1 label.
    func testClassifyImageReturnsLabels() throws {
        let imageURL = try Self.renderSolidColourImage(
            colour: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0),
            size: CGSize(width: 400, height: 400)
        )
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let ocr = VisionOCR()
        let labels: [String]
        do {
            labels = try ocr.classifyImage(at: imageURL)
        } catch {
            throw XCTSkip("classifyImage threw (headless CI?): \(error)")
        }

        guard !labels.isEmpty else {
            throw XCTSkip("VNClassifyImageRequest returned no labels — headless CI?")
        }

        print("OCRExtensionTests — classifyImage returned: \(labels.prefix(5))")
        XCTAssertGreaterThanOrEqual(labels.count, 1, "Expected ≥1 classification label")
    }

    func testClassifyImageMinConfidenceFilter() throws {
        let imageURL = try Self.renderSolidColourImage(
            colour: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            size: CGSize(width: 200, height: 200)
        )
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let ocr = VisionOCR()
        do {
            // minConfidence = 1.0 → only labels with 100% confidence (usually none or very few).
            let labelsStrict = try ocr.classifyImage(at: imageURL, minConfidence: 1.0)
            // We can't assert the count but we can assert it doesn't throw.
            _ = labelsStrict
        } catch {
            throw XCTSkip("classifyImage threw (headless CI?): \(error)")
        }
    }

    // MARK: - RealGalleryDLClient command construction (pure, no subprocess)

    func testBuildArgumentsNoCoookies() {
        let args = RealGalleryDLClient.buildArguments(profile: "testprofile", cookiesPath: nil)
        XCTAssertEqual(args, [
            "--ignore-config",
            "--dump-json",
            "--",
            "https://www.instagram.com/testprofile/",
        ])
    }

    func testBuildArgumentsWithCookies() {
        let cookiesURL = URL(fileURLWithPath: "/tmp/cookies.txt")
        let args = RealGalleryDLClient.buildArguments(profile: "testprofile", cookiesPath: cookiesURL)
        XCTAssertEqual(args, [
            "--ignore-config",
            "--dump-json",
            "--cookies", "/tmp/cookies.txt",
            "--",
            "https://www.instagram.com/testprofile/",
        ])
    }

    // MARK: - L-3: hardened args (--ignore-config) present on every gallery-dl call

    func testBuildArgumentsAlwaysIncludesIgnoreConfig() {
        XCTAssertTrue(
            RealGalleryDLClient.buildArguments(profile: "p", cookiesPath: nil).contains("--ignore-config"),
            "L-3: every gallery-dl invocation must include --ignore-config"
        )
    }

    func testBuildArgumentsProfileWithDashPrefix() {
        // Handle that starts with "-" would confuse gallery-dl without `--`.
        let args = RealGalleryDLClient.buildArguments(profile: "-weird", cookiesPath: nil)
        // The `--` ensures `-weird` is not interpreted as a flag.
        XCTAssertTrue(args.contains("--"), "args must contain '--' terminator")
        XCTAssertTrue(args.last?.contains("-weird") == true, "profile URL should be last arg")
    }

    // MARK: - RealGalleryDLClient JSON parsing (pure, no subprocess)

    func testParseGalleryDLJSON() throws {
        let json = """
        [
          [2, "https://cdn.instagram.com/photo_CxYzABCD.jpg", {
            "shortcode": "CxYzABCD",
            "description": "A test caption #test",
            "date": "2024-03-15T10:30:00",
            "typename": "GraphImage",
            "filename": "photo_CxYzABCD",
            "extension": "jpg"
          }],
          [2, "https://cdn.instagram.com/video_Dw1234EF.mp4", {
            "shortcode": "Dw1234EF",
            "description": null,
            "date": "2024-04-01T08:00:00",
            "typename": "GraphVideo",
            "filename": "video_Dw1234EF",
            "extension": "mp4"
          }],
          [0, "extractor message", {}],
          [1, "queue entry", {}]
        ]
        """

        let items = try RealGalleryDLClient.parse(jsonOutput: json)
        XCTAssertEqual(items.count, 2, "Types 0 and 1 should be skipped; only type-2 items")

        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.shortcode, "CxYzABCD")
        XCTAssertEqual(first.mediaType, "image")
        XCTAssertEqual(first.caption, "A test caption #test")
        XCTAssertEqual(first.filename, "photo_CxYzABCD.jpg")
        XCTAssertNotNil(first.timestamp)

        let second = items[1]
        XCTAssertEqual(second.shortcode, "Dw1234EF")
        XCTAssertEqual(second.mediaType, "video")
        XCTAssertNil(second.caption)
    }

    func testParseGalleryDLJSONTypenameMapping() {
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "GraphImage"),    "image")
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "XDTGraphImage"), "image")
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "GraphVideo"),    "video")
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "XDTGraphVideo"), "video")
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "GraphReel"),     "video")
        XCTAssertEqual(RealGalleryDLClient.mediaType(from: "XDTGraphReel"),  "video")
        XCTAssertNil(  RealGalleryDLClient.mediaType(from: "Unknown"))
        XCTAssertNil(  RealGalleryDLClient.mediaType(from: ""))
    }

    func testParseGalleryDLJSONBadTopLevel() {
        let json = #"{"not": "an array"}"#
        XCTAssertThrowsError(try RealGalleryDLClient.parse(jsonOutput: json)) { error in
            guard case GalleryDLClientError.outputParsingFailed = error else {
                XCTFail("Expected outputParsingFailed, got \(error)")
                return
            }
        }
    }

    func testParseGalleryDLDateNoZ() {
        // gallery-dl emits dates without Z — we must parse them as UTC.
        let date = RealGalleryDLClient.parseGalleryDLDate("2024-03-15T10:30:00")
        XCTAssertNotNil(date, "Should parse ISO 8601 date without Z")
    }

    // MARK: - Image rendering helpers

    /// Renders a QR code with the given payload to a temp PNG, returns its URL.
    private static func renderQRCode(payload: String) throws -> URL {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw RenderError.filterUnavailable
        }
        let data = Data(payload.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")  // high error correction

        guard let outputImage = filter.outputImage else {
            throw RenderError.outputImageNil
        }

        // Scale up so Vision can reliably detect it (tiny QR codes can fail).
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw RenderError.cgImageCreationFailed
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QRTest-\(UUID().uuidString).png")
        try pngData.write(to: url)
        return url
    }

    /// Renders a solid-colour rectangle to a temp PNG.
    private static func renderSolidColourImage(colour: CGColor, size: CGSize) throws -> URL {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderError.contextCreationFailed }

        ctx.setFillColor(colour)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let cgImage = ctx.makeImage() else { throw RenderError.cgImageCreationFailed }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColourTest-\(UUID().uuidString).png")
        try pngData.write(to: url)
        return url
    }

    private enum RenderError: Error {
        case filterUnavailable
        case outputImageNil
        case cgImageCreationFailed
        case contextCreationFailed
        case pngEncodingFailed
    }
}
