import Foundation
import Vision
import AppKit
import CoreImage

/// Performs on-device OCR using Apple Vision's `VNRecognizeTextRequest`.
///
/// All work is synchronous (the Vision request handler is used in single-shot mode)
/// so the struct needs no stored mutable state and is trivially `Sendable`.
public struct VisionOCR: Sendable {

    // MARK: - Initialisation

    public init() {}

    // MARK: - Recognition

    /// Recognises text in the image at `imageURL` and returns one string per
    /// text observation, in top-to-bottom reading order.
    ///
    /// - Parameters:
    ///   - imageURL: A `file://` URL pointing to the image (PNG, JPEG, HEIC, …).
    ///   - languages: BCP-47 language codes passed to the revision-3 recogniser.
    ///                Defaults to English + German, matching the podcast corpus.
    /// - Returns: An array of recognised strings (top candidate per observation).
    /// - Throws: ``VisionOCRError`` if the image cannot be loaded or the request fails.
    public func recognizeText(
        in imageURL: URL,
        languages: [String] = ["en-US", "de-DE"]
    ) throws -> [String] {
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            throw VisionOCRError.imageLoadFailed(imageURL)
        }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisionOCRError.cgImageConversionFailed
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        // Revision 3 ships on macOS 13+ and supports the language list above.
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        // Observations are already sorted top-to-bottom by Vision. Pick the
        // top candidate string for each observation.
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Convenience wrapper: recognises text and joins lines with `"\n"`.
    public func recognizeJoinedText(
        in imageURL: URL,
        languages: [String] = ["en-US", "de-DE"]
    ) throws -> String {
        try recognizeText(in: imageURL, languages: languages).joined(separator: "\n")
    }

    // MARK: - QR / Barcode detection

    /// Detects QR codes (and other barcodes) in the image at `imageURL` and returns
    /// the decoded payload strings.
    ///
    /// Uses `VNDetectBarcodesRequest` with the `.qr` symbology preferred. If Vision
    /// returns no results, an empty array is returned (not an error).
    ///
    /// - Throws: ``VisionOCRError`` if the image cannot be loaded or Vision fails.
    public func detectQRCodes(in imageURL: URL) throws -> [String] {
        let cgImage = try loadCGImage(from: imageURL)

        let request = VNDetectBarcodesRequest()
        // Limit to QR codes; Vision will still return others it finds but QR is primary.
        if #available(macOS 12, *) {
            request.symbologies = [.qr, .aztec, .dataMatrix]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.payloadStringValue }
    }

    // MARK: - Image classification (tags)

    /// Classifies the image at `imageURL` using `VNClassifyImageRequest` and returns
    /// the top label strings.
    ///
    /// Uses on-device classification (no cloud API). Labels with confidence below
    /// `minConfidence` are filtered out. Results are sorted by confidence descending.
    ///
    /// - Parameters:
    ///   - imageURL: A `file://` URL pointing to the image.
    ///   - minConfidence: Minimum confidence threshold (0–1). Default `0.1`.
    ///   - maxResults: Maximum number of labels to return. Default `20`.
    /// - Returns: Top label identifier strings (e.g. `"outdoor"`, `"food"`).
    /// - Throws: ``VisionOCRError`` if the image cannot be loaded.
    public func classifyImage(
        at imageURL: URL,
        minConfidence: Float = 0.1,
        maxResults: Int = 20
    ) throws -> [String] {
        let cgImage = try loadCGImage(from: imageURL)

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        return observations
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxResults)
            .map { $0.identifier }
    }

    // MARK: - Private helper

    private func loadCGImage(from imageURL: URL) throws -> CGImage {
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            throw VisionOCRError.imageLoadFailed(imageURL)
        }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisionOCRError.cgImageConversionFailed
        }
        return cgImage
    }
}

// MARK: - Error

public enum VisionOCRError: Error, Sendable {
    case imageLoadFailed(URL)
    case cgImageConversionFailed
    case requestFailed(Error)
}

// MARK: - Text extraction utilities

/// Pure functions for extracting structured entities from OCR text.
///
/// All methods are `static` so callers can use them without an `VisionOCR` instance,
/// and they operate on plain `String` so they compose with non-Vision text sources
/// (e.g. caption strings decoded from gallery-dl JSON).
public enum OCRExtraction: Sendable {

    /// Extracts Instagram-style `#hashtags` from `text`.
    ///
    /// ## Spec interpretation
    /// - Pattern: `#` followed by 1–100 word characters `[A-Za-z0-9_]` (no spaces).
    ///   Pure numeric tags (e.g. `#123`) are included (Instagram allows them).
    /// - Tags are **lowercased** and **de-duplicated** (first occurrence wins).
    /// - Tags are returned **without** the leading `#` character.
    /// - Leading `#` must be preceded by a word boundary (start of string,
    ///   whitespace, or punctuation) to avoid matching `##double` or mid-word `#`.
    ///
    /// ## Examples
    /// - `"#music #Podcast #music"` → `["music", "podcast"]`
    /// - `"text#nospace"` → `[]` (no word boundary before `#`)
    /// - `"check #out2024"` → `["out2024"]`
    public static func hashtags(in text: String) -> [String] {
        // `(?<!\w)` — not preceded by a word character (zero-width lookbehind).
        // This ensures the `#` is at the start or after whitespace/punctuation.
        let pattern = #"(?<!\w)#([A-Za-z0-9_]{1,100})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)

        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            // Capture group 1 is the tag text without the `#`.
            guard match.numberOfRanges > 1 else { continue }
            let tagRange = match.range(at: 1)
            guard tagRange.location != NSNotFound else { continue }
            let raw = nsText.substring(with: tagRange).lowercased()
            if seen.insert(raw).inserted {
                result.append(raw)
            }
        }
        return result
    }

    /// Extracts Instagram-style @handles from `text`.
    ///
    /// Return convention: handles are returned **with** the leading `@` character,
    /// lowercased, de-duplicated (first occurrence wins), in left-to-right order of
    /// first appearance.
    ///
    /// Pattern: `@` followed by 2–30 characters drawn from `[A-Za-z0-9._]`.
    public static func mentions(in text: String) -> [String] {
        let pattern = #"@[A-Za-z0-9._]{2,30}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)

        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            let raw = nsText.substring(with: match.range).lowercased()
            if seen.insert(raw).inserted {
                result.append(raw)
            }
        }
        return result
    }

    /// Extracts http(s) URLs from `text` using `NSDataDetector`.
    ///
    /// Returns URL strings as they appear in the text (no lowercasing),
    /// de-duplicated (first occurrence wins), in left-to-right order.
    public static func urls(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)

        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            guard let url = match.url else { continue }
            let scheme = url.scheme ?? ""
            guard scheme == "http" || scheme == "https" else { continue }
            let str = url.absoluteString
            if seen.insert(str).inserted {
                result.append(str)
            }
        }
        return result
    }
}
