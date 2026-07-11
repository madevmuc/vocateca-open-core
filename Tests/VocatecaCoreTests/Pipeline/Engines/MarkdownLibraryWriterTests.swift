import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - MarkdownLibraryWriterTests

final class MarkdownLibraryWriterTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLibraryWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePodcastEpisode(
        guid: String = "ep-abc123",
        showSlug: String = "test-show",
        title: String = "Test Episode",
        pubDate: String = "2024-01-15"
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: pubDate,
            mp3Url: "https://example.com/\(guid).mp3"
        )
    }

    private func makeIGPostEpisode(
        guid: String = "ig-post-xyz",
        showSlug: String = "myprofile",
        igProfile: String = "myprofile",
        igShortcode: String = "Cxyz1234",
        title: String = "IG Post Title",
        pubDate: String = "2024-02-20",
        description: String? = "Hello #world @user"
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: pubDate,
            mp3Url: "https://www.instagram.com/p/Cxyz1234/",
            description: description,
            igShortcode: igShortcode,
            igProfile: igProfile,
            igKind: "post",
            mediaType: "image"
        )
    }

    // MARK: - Podcast transcript: .md structure matches TranscriptFormat

    /// Verifies that the written markdown has the correct structure produced by
    /// `TranscriptFormat.frontmatter` + `banner` + `srtToPlainText`.
    ///
    /// Note: `transcribed_at` uses `Date()` (live clock) in both the writer and
    /// this test, so we pin it to a fixed string to make the comparison
    /// byte-for-byte deterministic. The writer uses `TranscriptFormat.frontmatter`
    /// which delegates to the default `transcribedAt: ""` path (live clock).
    /// We therefore compare everything EXCEPT the `transcribed_at:` line, which
    /// we assert is present with the correct key format.
    func testPodcastTranscriptMatchesTranscriptFormat() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(
            guid: "ep-abc123",
            showSlug: "test-show",
            pubDate: "2024-01-15"
        )
        let segments = [
            TranscriptionSegment(start: 0.0, end: 2.5, text: "Hello world"),
            TranscriptionSegment(start: 2.5, end: 5.0, text: "this is a test"),
        ]
        let transcript = TranscriptionResult(
            text: "Hello world this is a test",
            segments: segments,
            language: "en"
        )

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: true)
        let mdURL = try await writer.write(
            episode: episode,
            transcript: transcript,
            ocrText: nil,
            mediaPath: nil
        )

        // File must exist and be readable.
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))

        let writtenContent = try String(contentsOf: mdURL, encoding: .utf8)

        // Verify YAML frontmatter keys are present.
        XCTAssertTrue(writtenContent.contains("guid: \"ep-abc123\""),         "guid in frontmatter")
        XCTAssertTrue(writtenContent.contains("show_slug: \"test-show\""),    "show_slug in frontmatter")
        XCTAssertTrue(writtenContent.contains("title: \"Test Episode\""),     "title in frontmatter")
        XCTAssertTrue(writtenContent.contains("pub_date: \"2024-01-15\""),    "pub_date in frontmatter")
        XCTAssertTrue(writtenContent.contains("transcribed_at: \""),          "transcribed_at in frontmatter")

        // Verify banner.
        XCTAssertTrue(writtenContent.contains("> [!info] Episode vom 2024-01-15"), "banner present")

        // Verify transcript body (from srtToPlainText).
        XCTAssertTrue(writtenContent.contains("Hello world"),       "transcript text present")
        XCTAssertTrue(writtenContent.contains("this is a test"),    "transcript text present")

        // Verify structure: strip the transcribed_at line and compare the rest
        // to the pinned expected output from TranscriptFormat.
        let pinnedTS = "2024-06-28T00:00:00.000Z"
        let srtText = WhisperKitTranscriptionEngine.buildSRT(segments: segments)
        let pinnedFM = TranscriptFormat.frontmatter(
            meta: [
                "guid":      episode.guid,
                "show_slug": episode.showSlug,
                "title":     episode.title,
                "pub_date":  episode.pubDate,
                "mp3_url":   episode.mp3Url,
            ],
            detectedLanguage: episode.detectedLanguage,
            transcribedAt: pinnedTS
        )
        // v2 adds an Obsidian show wikilink after the frontmatter (additive-only;
        // this episode has no durationSec/wordCount/transcriptOrigin, so no other
        // enrichment keys are emitted — see MarkdownLibraryWriter.obsidianEnrichment).
        let showWikilink = "> [[\(episode.showSlug)]]\n\n"
        let bannerStr = TranscriptFormat.banner(pubDate: episode.pubDate)
        let body = TranscriptFormat.srtToPlainText(srtText)
        let pinnedExpected = pinnedFM + showWikilink + bannerStr + body + "\n"

        // Compare with transcribed_at line removed from both sides.
        func stripTranscribedAt(_ s: String) -> String {
            s.components(separatedBy: "\n")
             .filter { !$0.hasPrefix("transcribed_at:") }
             .joined(separator: "\n")
        }

        XCTAssertEqual(
            stripTranscribedAt(writtenContent),
            stripTranscribedAt(pinnedExpected),
            "Podcast .md structure must match TranscriptFormat output (transcribed_at excluded)"
        )
    }

    // MARK: - Podcast transcript: SRT sidecar is well-formed

    func testPodcastTranscriptSRTSidecar() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(guid: "ep-srt-test", showSlug: "my-show")
        let segments = [
            TranscriptionSegment(start: 0.0,   end: 1.5,   text: "First line"),
            TranscriptionSegment(start: 1.5,   end: 61.25, text: "Second line"),
            TranscriptionSegment(start: 61.25, end: 90.0,  text: "Third line"),
        ]
        let transcript = TranscriptionResult(
            text: "First line Second line Third line",
            segments: segments,
            language: "de"
        )

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: true)
        _ = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let slug = MarkdownLibraryWriter.makeSlug(episode)
        let srtURL = tmpDir
            .appendingPathComponent(episode.showSlug)
            .appendingPathComponent("\(slug).srt")

        XCTAssertTrue(FileManager.default.fileExists(atPath: srtURL.path),
                      "SRT sidecar must be written when writeSRT=true")

        let srtContent = try String(contentsOf: srtURL, encoding: .utf8)

        // SRT must start with "1\n".
        XCTAssertTrue(srtContent.hasPrefix("1\n"),
                      "SRT must start with cue index 1")

        // Must contain the timestamp format HH:MM:SS,mmm --> HH:MM:SS,mmm.
        let tsPattern = #"\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}"#
        let re = try NSRegularExpression(pattern: tsPattern)
        let matches = re.matches(in: srtContent, range: NSRange(srtContent.startIndex..., in: srtContent))
        XCTAssertEqual(matches.count, 3, "Three timestamp lines expected")

        // Must contain all three segment texts.
        XCTAssertTrue(srtContent.contains("First line"))
        XCTAssertTrue(srtContent.contains("Second line"))
        XCTAssertTrue(srtContent.contains("Third line"))
    }

    func testMirrorsToKnowledgeHubExportRoots() async throws {
        let tmpDir = try makeTempDir()
        let exportA = try makeTempDir()
        let exportB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
            try? FileManager.default.removeItem(at: exportA)
            try? FileManager.default.removeItem(at: exportB)
        }

        let episode = makePodcastEpisode(guid: "ep-mirror", showSlug: "my-show")
        let transcript = TranscriptionResult(
            text: "Hello world", segments: [TranscriptionSegment(start: 0, end: 1, text: "Hello world")],
            language: "en")

        let writer = MarkdownLibraryWriter(
            outputRoot: tmpDir, writeSRT: false, exportRoots: [exportA, exportB])
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let slug = MarkdownLibraryWriter.makeSlug(episode)
        let expected = try String(contentsOf: mdURL, encoding: .utf8)

        for root in [exportA, exportB] {
            let mirrored = root.appendingPathComponent("my-show").appendingPathComponent("\(slug).md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored.path),
                          "transcript must be mirrored to \(root.lastPathComponent)")
            XCTAssertEqual(try String(contentsOf: mirrored, encoding: .utf8), expected,
                           "mirrored copy must match the primary transcript")
        }
    }

    // MARK: - IG image post: caption + OCR sections

    func testInstagramPostWritesCaptionAndOCR() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makeIGPostEpisode(
            guid: "ig-post-xyz",
            igProfile: "myprofile",
            igShortcode: "Cxyz1234",
            description: "Hello #world @user"
        )
        let ocrText = "Recognised text from image\nSecond OCR line"

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: true)
        let mdURL = try await writer.write(
            episode: episode,
            transcript: nil,
            ocrText: ocrText,
            mediaPath: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))

        let content = try String(contentsOf: mdURL, encoding: .utf8)

        // Must contain the caption section.
        XCTAssertTrue(content.contains("## Caption"), "Must have ## Caption section")
        XCTAssertTrue(content.contains("Hello #world @user"), "Caption text must be present")

        // Must contain the OCR section.
        XCTAssertTrue(content.contains("## OCR"), "Must have ## OCR section")
        XCTAssertTrue(content.contains("Recognised text from image"), "OCR text must be present")
        XCTAssertTrue(content.contains("Second OCR line"), "Second OCR line must be present")

        // Must contain frontmatter markers.
        XCTAssertTrue(content.hasPrefix("---\n"), "Must start with frontmatter ---")
        XCTAssertTrue(content.contains("ig_shortcode: Cxyz1234"))
        XCTAssertTrue(content.contains("ig_profile: myprofile"))
    }

    // MARK: - IG image post: no OCR text

    func testInstagramPostNoOCR() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makeIGPostEpisode(description: nil)
        let writer = MarkdownLibraryWriter(outputRoot: tmpDir)
        let mdURL = try await writer.write(
            episode: episode, transcript: nil, ocrText: nil, mediaPath: nil
        )

        let content = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(content.contains("_(no caption)_"))
        XCTAssertTrue(content.contains("_(no OCR text)_"))
    }

    // MARK: - Security: path traversal is neutralized

    /// A malicious igProfile/igShortcode (from gallery-dl metadata) must NOT let
    /// the written file escape the output root. Regression for the Phase-6
    /// security-review path-traversal finding.
    func testInstagramPostPathTraversalNeutralized() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makeIGPostEpisode(
            igProfile: "../../../../etc",
            igShortcode: "../../../../../../tmp/evil"
        )
        let writer = MarkdownLibraryWriter(outputRoot: tmpDir)
        let mdURL = try await writer.write(
            episode: episode, transcript: nil, ocrText: "x", mediaPath: nil
        )

        // The resolved file must be INSIDE outputRoot (no traversal escape).
        // safePathSegment turns "../../etc" into "etc", so the file legitimately
        // lands at <root>/etc/<sanitized-shortcode>.md — inside the root, with no
        // ".." surviving in the standardized path.
        let root = tmpDir.standardizedFileURL.path
        let written = mdURL.standardizedFileURL.path
        XCTAssertTrue(written.hasPrefix(root + "/"),
                      "written path \(written) escaped output root \(root)")
        XCTAssertFalse(written.contains(".."), "no traversal component may survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
    }

    func testSafePathSegmentPreservesCaseAndBlocksTraversal() {
        XCTAssertEqual(TextNormalization.safePathSegment("Cxyz1234"), "Cxyz1234")  // case kept
        XCTAssertEqual(TextNormalization.safePathSegment("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(TextNormalization.safePathSegment("a/b\\c"), "abc")
        XCTAssertEqual(TextNormalization.safePathSegment("...."), "_")  // all dots → fallback
        XCTAssertEqual(TextNormalization.safePathSegment("ok_-9"), "ok_-9")
    }

    // MARK: - Atomic write: overwrite existing

    func testAtomicOverwrite() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(guid: "ep-overwrite", showSlug: "show-a")
        let segment1 = TranscriptionSegment(start: 0, end: 1, text: "First version")
        let transcript1 = TranscriptionResult(text: "First version", segments: [segment1], language: nil)

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false)
        let mdURL = try await writer.write(episode: episode, transcript: transcript1, ocrText: nil, mediaPath: nil)

        let content1 = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(content1.contains("First version"))

        // Overwrite with new content.
        let segment2 = TranscriptionSegment(start: 0, end: 1, text: "Updated version")
        let transcript2 = TranscriptionResult(text: "Updated version", segments: [segment2], language: nil)
        _ = try await writer.write(episode: episode, transcript: transcript2, ocrText: nil, mediaPath: nil)

        let content2 = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(content2.contains("Updated version"), "Overwritten content must reflect new transcript")
        XCTAssertFalse(content2.contains("First version"), "Old content must be gone")
    }

    // MARK: - OKF (Open Knowledge Format) sidecar

    /// `writeOKF: true` must emit a `<slug>.okf.md` sidecar with valid YAML
    /// frontmatter (type/title/resource/source/tags/timestamp) and a
    /// timestamped `## Transcript` body built from the same segments as the
    /// primary `.md`. No `speakers:` key when diarization is absent.
    func testOKFSidecarWrittenWhenEnabled() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(
            guid: "ep-okf-1", showSlug: "my-show", title: "My Episode Title", pubDate: "2024-03-10"
        )
        let segments = [
            TranscriptionSegment(start: 0.0, end: 2.5, text: "Hello world"),
            TranscriptionSegment(start: 65.0, end: 68.0, text: "this is a test"),
        ]
        let transcript = TranscriptionResult(text: "Hello world this is a test", segments: segments, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false, writeOKF: true)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let okfURL = mdURL.deletingLastPathComponent()
            .appendingPathComponent(mdURL.deletingPathExtension().lastPathComponent + ".okf.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: okfURL.path), "expected .okf.md sidecar at \(okfURL.path)")

        let okf = try String(contentsOf: okfURL, encoding: .utf8)
        XCTAssertTrue(okf.hasPrefix("---\n"), "OKF must start with a YAML frontmatter block")
        XCTAssertTrue(okf.contains("type: reference"), "frontmatter must declare type: reference")
        XCTAssertTrue(okf.contains("title: \"My Episode Title\""), "frontmatter must carry the title")
        XCTAssertTrue(okf.contains("resource: \"\(episode.mp3Url)\""), "frontmatter must carry the source URL")
        XCTAssertTrue(okf.contains("source: \"podcast\""), "frontmatter must classify the source")
        XCTAssertTrue(okf.contains("tags: [transcript, my-show]"), "frontmatter must tag transcript + show slug")
        XCTAssertTrue(okf.contains("timestamp: \"2024-03-10\""), "frontmatter must carry the pub date as timestamp")
        XCTAssertFalse(okf.contains("speakers:"), "no diarization ⇒ no speakers key")

        XCTAssertTrue(okf.contains("# My Episode Title"), "body must open with an H1 title")
        XCTAssertTrue(okf.contains("## Transcript"), "body must have a Transcript section")
        XCTAssertTrue(okf.contains("**[00:00]** Hello world"), "first segment timestamped MM:SS, no speaker prefix")
        XCTAssertTrue(okf.contains("**[01:05]** this is a test"), "second segment timestamp rolls minutes correctly")
    }

    /// When diarization has assigned speakers, the OKF frontmatter lists them
    /// and the body prefixes each line with `Speaker N:`.
    func testOKFSidecarIncludesSpeakersWhenDiarized() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(guid: "ep-okf-2", showSlug: "my-show", pubDate: "2024-03-10")
        let segments = [
            TranscriptionSegment(start: 0.0, end: 2.0, text: "Hi there", speaker: 0),
            TranscriptionSegment(start: 2.0, end: 4.0, text: "Hello back", speaker: 1),
        ]
        let transcript = TranscriptionResult(text: "Hi there Hello back", segments: segments, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false, writeOKF: true)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)
        let okfURL = mdURL.deletingLastPathComponent()
            .appendingPathComponent(mdURL.deletingPathExtension().lastPathComponent + ".okf.md")
        let okf = try String(contentsOf: okfURL, encoding: .utf8)

        XCTAssertTrue(okf.contains("speakers: [\"Speaker 1\", \"Speaker 2\"]"), "frontmatter must list distinct speakers")
        XCTAssertTrue(okf.contains("**[00:00]** Speaker 1: Hi there"))
        XCTAssertTrue(okf.contains("**[00:02]** Speaker 2: Hello back"))
    }

    /// `writeOKF: false` (the default) must not write a `.okf.md` sidecar.
    func testOKFSidecarSkippedWhenDisabled() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = makePodcastEpisode(guid: "ep-okf-3", showSlug: "my-show", pubDate: "2024-03-10")
        let segments = [TranscriptionSegment(start: 0, end: 1, text: "Hello")]
        let transcript = TranscriptionResult(text: "Hello", segments: segments, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)
        let okfURL = mdURL.deletingLastPathComponent()
            .appendingPathComponent(mdURL.deletingPathExtension().lastPathComponent + ".okf.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: okfURL.path), "no .okf.md sidecar unless writeOKF is true")
    }

    // MARK: - Slug sanitisation

    func testSlugSanitisesSpecialChars() {
        let episode = Episode(
            guid: "Ep With Spaces & Symbols! 🎙",
            showSlug: "show",
            title: "T",
            pubDate: "2024-01-01",
            mp3Url: "https://x.com/e.mp3"
        )
        let slug = MarkdownLibraryWriter.makeSlug(episode)
        let forbiddenChars = CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).inverted
        XCTAssertTrue(
            slug.unicodeScalars.allSatisfy { !forbiddenChars.contains($0) },
            "Slug must only contain alphanumeric, hyphen, underscore"
        )
        XCTAssertFalse(slug.isEmpty, "Slug must not be empty")
    }
}
