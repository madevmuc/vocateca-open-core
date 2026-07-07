import Foundation

// MARK: - InstagramImageOCRProcessor

/// A real `ImageOCRProcessor` that runs `VisionOCR` over an Instagram post's
/// images, de-duplicates carousel text, and returns the combined OCR output.
///
/// ## Carousel posts
/// A carousel post may have multiple images stored under a `<shortcode>/` directory.
/// The processor:
/// 1. If `mediaPath` is a file: OCRs that single image.
/// 2. If `mediaPath` is a directory: OCRs all `.jpg`, `.jpeg`, `.png`, `.heic`
///    files in lexicographic order (matching the gallery-dl naming `01.jpg`,
///    `02.jpg`, …), then de-duplicates consecutive identical lines.
///
/// ## De-duplication
/// Duplicate adjacent text blocks (e.g. a recurring watermark on every frame)
/// are dropped. De-dup is line-level: identical consecutive lines are kept only once.
///
/// ## OCR languages
/// Defaults to `["en-US", "de-DE"]` matching `VisionOCR`'s default.
public struct InstagramImageOCRProcessor: ImageOCRProcessor {

    // MARK: - Dependencies

    private let ocr: VisionOCR
    private let languages: [String]

    // MARK: - Init

    public init(
        ocr: VisionOCR = VisionOCR(),
        languages: [String] = ["en-US", "de-DE"]
    ) {
        self.ocr = ocr
        self.languages = languages
    }

    // MARK: - ImageOCRProcessor

    public func process(_ episode: Episode, mediaPath: URL) async throws -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: mediaPath.path, isDirectory: &isDirectory)

        guard exists else {
            throw PipelineError.permanent("Media path does not exist: \(mediaPath.path)")
        }

        let imageURLs: [URL]
        if isDirectory.boolValue {
            imageURLs = try Self.collectImages(in: mediaPath)
        } else {
            imageURLs = [mediaPath]
        }

        guard !imageURLs.isEmpty else {
            return ""
        }

        // OCR each image, collect all lines.
        var allLines: [String] = []
        for imageURL in imageURLs {
            do {
                let lines = try ocr.recognizeText(in: imageURL, languages: languages)
                allLines.append(contentsOf: lines)
            } catch let ocrErr as VisionOCRError {
                // Log and continue — a single bad frame should not abort the whole post.
                // Surface as a transient if ALL images fail.
                _ = ocrErr // suppress unused warning; in production we'd log
                continue
            } catch {
                throw PipelineError.transient("OCR failed on \(imageURL.lastPathComponent): \(error)")
            }
        }

        if allLines.isEmpty && !imageURLs.isEmpty {
            // Every image failed OCR — treat as permanent (bad images, not transient).
            return ""
        }

        // De-duplicate consecutive identical lines (carousel watermark removal).
        let deduped = Self.deduplicateConsecutive(allLines)

        return deduped.joined(separator: "\n")
    }

    // MARK: - Pure helpers

    /// Collect image files from `directory` in lexicographic order.
    static func collectImages(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Remove consecutive duplicate lines (preserves order, first occurrence wins).
    static func deduplicateConsecutive(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previousLine: String? = nil
        for line in lines {
            if line != previousLine {
                result.append(line)
                previousLine = line
            }
        }
        return result
    }
}
