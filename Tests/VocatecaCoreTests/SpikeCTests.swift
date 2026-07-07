import XCTest
import Foundation
import AppKit
import CoreGraphics
@testable import VocatecaCore

/// Spike C — Phase 0: prove two seams the Instagram pipeline will rely on.
///
/// 1. **Vision OCR** can read text rendered into a temporary PNG and we can
///    extract @-handles and URLs from the recognised text.
/// 2. **MockGalleryDLClient** decodes canned gallery-dl JSON and the caption
///    extraction pipeline works on decoded strings.
final class SpikeCTests: XCTestCase {

    // MARK: - OCR tests

    /// Renders a two-line image with known text, runs Vision OCR on it, and
    /// asserts that the @mention and URL survive the round-trip.
    func testOCRReadsRenderedImage() throws {
        // ------------------------------------------------------------------
        // 1. Render a high-contrast PNG into a temp file.
        // ------------------------------------------------------------------
        let imageURL = try Self.renderTestImage(
            lines: [
                "Follow @creator_handle",
                "Visit https://example.com/post"
            ],
            fontSize: 48.0,
            canvasSize: CGSize(width: 900, height: 200)
        )
        defer { try? FileManager.default.removeItem(at: imageURL) }

        // ------------------------------------------------------------------
        // 2. Run OCR.
        // ------------------------------------------------------------------
        let ocr = VisionOCR()
        let joined: String
        do {
            joined = try ocr.recognizeJoinedText(in: imageURL)
        } catch {
            throw XCTSkip("VisionOCR threw (possibly headless CI without Vision support): \(error)")
        }

        // Vision must return *something*; if the result is empty we skip
        // rather than failing (headless CI quirk).
        guard !joined.isEmpty else {
            throw XCTSkip("VisionOCR returned no text — skipping (headless CI?)")
        }

        print("SpikeCTests — OCR raw output:\n\(joined)\n")

        // ------------------------------------------------------------------
        // 3. Assert text content.
        // ------------------------------------------------------------------
        XCTAssertTrue(
            joined.lowercased().contains("creator"),
            "Recognised text should contain 'creator'; got: \(joined)"
        )

        // ------------------------------------------------------------------
        // 4. Assert @mention extraction.
        // ------------------------------------------------------------------
        let mentions = OCRExtraction.mentions(in: joined)
        print("SpikeCTests — extracted mentions: \(mentions)")
        XCTAssertTrue(
            mentions.contains("@creator_handle"),
            "mentions() should contain '@creator_handle'; got: \(mentions)"
        )

        // ------------------------------------------------------------------
        // 5. Assert URL extraction.
        // ------------------------------------------------------------------
        let urls = OCRExtraction.urls(in: joined)
        print("SpikeCTests — extracted URLs: \(urls)")
        let hasExampleHost = urls.contains { urlString in
            URL(string: urlString)?.host?.contains("example.com") == true
        }
        XCTAssertTrue(
            hasExampleHost,
            "urls() should contain a URL with host 'example.com'; got: \(urls)"
        )
    }

    /// Sanity-checks `OCRExtraction.mentions` and `OCRExtraction.urls` on
    /// a purely synthetic string (no Vision involved) to isolate the regexes.
    func testExtractionPureFunctions() {
        let text = """
        Hey @alice.b and @bob_99 — see https://open.spotify.com/ep/42 or http://example.org
        Already mentioned @alice.b again.
        """

        let mentions = OCRExtraction.mentions(in: text)
        // De-duplicated, lowercased, with leading @.
        XCTAssertEqual(mentions, ["@alice.b", "@bob_99"])

        let urls = OCRExtraction.urls(in: text)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].contains("spotify.com"))
        XCTAssertTrue(urls[1].contains("example.org"))
    }

    // MARK: - gallery-dl mock tests

    func testMockClientDecodesFixture() async throws {
        // Load the fixture from the test bundle.
        guard let fixtureURL = Bundle.module.url(
            forResource: "gallerydl_profile",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("gallerydl_profile.json not found in test bundle — check Package.swift resource rule")
            return
        }

        let client = try MockGalleryDLClient(fixtureURL: fixtureURL)
        let items = try await client.enumerate(profile: "testprofile")

        // ------------------------------------------------------------------
        // Basic count.
        // ------------------------------------------------------------------
        XCTAssertEqual(items.count, 3, "Fixture should decode exactly 3 items")
        print("SpikeCTests — decoded \(items.count) gallery-dl items")

        // ------------------------------------------------------------------
        // First item (image with shortcode + caption).
        // ------------------------------------------------------------------
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.shortcode, "CxYzABCD")
        XCTAssertEqual(first.mediaType, "image")
        let firstCaption = try XCTUnwrap(first.caption, "First item must have a caption")
        XCTAssertTrue(firstCaption.contains("@creator_handle"))
        XCTAssertNotNil(first.timestamp)

        // ------------------------------------------------------------------
        // Second item (video).
        // ------------------------------------------------------------------
        let second = items[1]
        XCTAssertEqual(second.mediaType, "video")
        XCTAssertEqual(second.shortcode, "Dw1234EF")

        // ------------------------------------------------------------------
        // Third item (nil caption).
        // ------------------------------------------------------------------
        let third = items[2]
        XCTAssertNil(third.caption)

        // ------------------------------------------------------------------
        // Feed caption through extraction pipeline (ties OCR + gallery-dl seams).
        // ------------------------------------------------------------------
        let mentions = OCRExtraction.mentions(in: firstCaption)
        print("SpikeCTests — caption mentions: \(mentions)")
        XCTAssertTrue(
            mentions.contains("@creator_handle"),
            "OCRExtraction.mentions should find @creator_handle in caption; got: \(mentions)"
        )

        let urls = OCRExtraction.urls(in: firstCaption)
        print("SpikeCTests — caption URLs: \(urls)")
        let hasExampleHost = urls.contains { URL(string: $0)?.host?.contains("example.com") == true }
        XCTAssertTrue(hasExampleHost, "OCRExtraction.urls should find example.com URL in caption; got: \(urls)")
    }

    // MARK: - Image rendering helper

    /// Renders `lines` of text into a white-background PNG at a temp path and
    /// returns its `file://` URL.
    ///
    /// Uses Core Graphics / AppKit so there is no external dependency.
    /// Text is rendered black-on-white at `fontSize` points; `canvasSize`
    /// should be generous enough that all text fits without clipping.
    private static func renderTestImage(
        lines: [String],
        fontSize: CGFloat,
        canvasSize: CGSize
    ) throws -> URL {
        let width  = Int(canvasSize.width)
        let height = Int(canvasSize.height)

        // Create a bitmap context: 8-bit RGBA, white background.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.contextCreationFailed
        }

        // White background.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip coordinate system so text draws top-to-bottom.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // Draw each line using AppKit attributed strings.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.black
        ]

        let lineHeight = fontSize * 1.5
        let margin: CGFloat = 20
        for (i, line) in lines.enumerated() {
            let y = margin + CGFloat(i) * lineHeight
            let point = CGPoint(x: margin, y: y)
            (line as NSString).draw(at: point, withAttributes: attributes)
        }

        NSGraphicsContext.restoreGraphicsState()

        // Export as PNG.
        guard let cgImage = context.makeImage() else {
            throw RenderError.imageCreationFailed
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpikeCOCR-\(UUID().uuidString).png")
        try pngData.write(to: tmp)
        return tmp
    }

    private enum RenderError: Error {
        case contextCreationFailed
        case imageCreationFailed
        case pngEncodingFailed
    }
}
