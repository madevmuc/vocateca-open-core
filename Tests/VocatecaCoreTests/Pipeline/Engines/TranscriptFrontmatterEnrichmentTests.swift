import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - TranscriptFrontmatterEnrichmentTests

/// Golden tests for the v2 Obsidian-enrichment frontmatter fields (Task 8 of
/// the Integrations feature). These are a **deliberate, additive-only**
/// divergence from the oracle-locked v1 `_fmt_frontmatter` / `render_episode_markdown`
/// ports: v2 appends `transcript_origin`, `duration_sec`, `word_count`, and
/// (non-podcast only) `source_url` after the existing keys, plus an Obsidian
/// `[[show_slug]]` wikilink in the banner area. Every existing oracle-locked
/// key must still appear, unchanged, in its original position.
///
/// Deterministic: all inputs are fixed, `transcribedAt` is pinned, so no
/// wall-clock dependency.
final class TranscriptFrontmatterEnrichmentTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrontmatterEnrichmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Podcast path: enriched frontmatter via MarkdownLibraryWriter

    func testPodcastFrontmatterIsEnrichedWithProvenanceDurationWordCount() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = Episode(
            guid: "ep-enrich-1",
            showSlug: "the-daily-show",
            title: "Enriched Episode",
            pubDate: "2024-03-10",
            mp3Url: "https://example.com/ep-enrich-1.mp3",
            durationSec: 1830,
            wordCount: 4521,
            transcriptOrigin: "asr:whisper:large-v3-turbo"
        )
        let segments = [TranscriptionSegment(start: 0, end: 2, text: "Hello enriched world")]
        let transcript = TranscriptionResult(text: "Hello enriched world", segments: segments, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)
        let content = try String(contentsOf: mdURL, encoding: .utf8)

        // Existing oracle-locked keys must remain, unchanged.
        XCTAssertTrue(content.contains("guid: \"ep-enrich-1\""))
        XCTAssertTrue(content.contains("show_slug: \"the-daily-show\""))
        XCTAssertTrue(content.contains("title: \"Enriched Episode\""))
        XCTAssertTrue(content.contains("pub_date: \"2024-03-10\""))
        XCTAssertTrue(content.contains("mp3_url: \"https://example.com/ep-enrich-1.mp3\""))
        XCTAssertTrue(content.contains("transcribed_at: \""))

        // New v2 enrichment keys.
        XCTAssertTrue(content.contains("transcript_origin: \"asr:whisper:large-v3-turbo\""),
                      "transcript_origin must be present")
        XCTAssertTrue(content.contains("duration_sec: \"1830\""), "duration_sec must be present")
        XCTAssertTrue(content.contains("word_count: \"4521\""), "word_count must be present")

        // Obsidian show wikilink somewhere in the document (banner area).
        XCTAssertTrue(content.contains("[[the-daily-show]]"), "Obsidian show wikilink must be present")
    }

    // MARK: - Podcast path: fields skipped when absent

    func testPodcastFrontmatterOmitsMissingEnrichmentFields() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // No durationSec / wordCount / transcriptOrigin supplied.
        let episode = Episode(
            guid: "ep-bare",
            showSlug: "bare-show",
            title: "Bare Episode",
            pubDate: "2024-03-11",
            mp3Url: "https://example.com/ep-bare.mp3"
        )
        let transcript = TranscriptionResult(
            text: "hi", segments: [TranscriptionSegment(start: 0, end: 1, text: "hi")], language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)
        let content = try String(contentsOf: mdURL, encoding: .utf8)

        XCTAssertFalse(content.contains("transcript_origin:"), "must be omitted when nil")
        XCTAssertFalse(content.contains("duration_sec:"), "must be omitted when nil")
        XCTAssertFalse(content.contains("word_count:"), "must be omitted when nil")
        // Show wikilink is independent of these fields — still present.
        XCTAssertTrue(content.contains("[[bare-show]]"))
    }

    // MARK: - YouTube path: enriched frontmatter + source_url

    func testYouTubeFrontmatterIsEnrichedWithSourceURL() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let episode = Episode(
            guid: "yt-enrich-1",
            showSlug: "yt-show",
            title: "YT Enriched Episode",
            pubDate: "2024-05-01",
            mp3Url: "https://www.youtube.com/watch?v=abc123XYZ",
            durationSec: 600,
            wordCount: 1200,
            transcriptOrigin: "captions:auto"
        )
        let transcript = TranscriptionResult(
            text: "yt hello", segments: [TranscriptionSegment(start: 0, end: 1, text: "yt hello")], language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmpDir, writeSRT: false)
        let mdURL = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)
        let content = try String(contentsOf: mdURL, encoding: .utf8)

        // Existing oracle-locked keys.
        XCTAssertTrue(content.contains("show_slug: yt-show"))
        XCTAssertTrue(content.contains("title: YT Enriched Episode"))
        XCTAssertTrue(content.contains("source: youtube"))

        // New v2 enrichment keys (unquoted, matching renderEpisodeMarkdown's style).
        XCTAssertTrue(content.contains("transcript_origin: captions:auto"))
        XCTAssertTrue(content.contains("duration_sec: 600"))
        XCTAssertTrue(content.contains("word_count: 1200"))
        XCTAssertTrue(content.contains("source_url: https://www.youtube.com/watch?v=abc123XYZ"),
                      "source_url must mirror mp3Url for the non-podcast path")

        XCTAssertTrue(content.contains("[[yt-show]]"), "Obsidian show wikilink must be present")
    }

    // MARK: - Direct TranscriptFormat.frontmatter unit test: extra is additive-only

    func testFrontmatterExtraIsAppendedAfterExistingKeysWithoutAlteringThem() {
        let baseline = TranscriptFormat.frontmatter(
            meta: [
                "guid": "g1", "show_slug": "s1", "title": "t1",
                "pub_date": "2024-01-01", "mp3_url": "https://x/1.mp3",
            ],
            detectedLanguage: "en",
            transcribedAt: "2024-06-28T00:00:00.000Z"
        )
        let enriched = TranscriptFormat.frontmatter(
            meta: [
                "guid": "g1", "show_slug": "s1", "title": "t1",
                "pub_date": "2024-01-01", "mp3_url": "https://x/1.mp3",
            ],
            detectedLanguage: "en",
            transcribedAt: "2024-06-28T00:00:00.000Z",
            extra: [("transcript_origin", "asr:whisper:tiny"), ("word_count", "10")]
        )

        // Every line of baseline must appear verbatim in enriched (additive-only).
        let baselineLines = baseline.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in baselineLines where line != "---" {
            XCTAssertTrue(enriched.contains(line), "baseline line dropped/altered: \(line)")
        }
        XCTAssertTrue(enriched.contains("transcript_origin: \"asr:whisper:tiny\""))
        XCTAssertTrue(enriched.contains("word_count: \"10\""))

        // No-extra call must remain byte-identical to the pre-enrichment oracle-locked output.
        XCTAssertEqual(
            TranscriptFormat.frontmatter(
                meta: ["guid": "g1", "show_slug": "s1", "title": "t1",
                       "pub_date": "2024-01-01", "mp3_url": "https://x/1.mp3"],
                detectedLanguage: "en",
                transcribedAt: "2024-06-28T00:00:00.000Z"
            ),
            baseline
        )
    }

    func testRenderEpisodeMarkdownExtraIsAdditiveOnly() {
        let baseline = TranscriptFormat.renderEpisodeMarkdown(
            showSlug: "s1", title: "t1", srtText: "1\n00:00:00,000 --> 00:00:01,000\nhi\n\n",
            source: "youtube", youtubeID: "abc", pubDate: "2024-01-01",
            now: Date(timeIntervalSince1970: 0)
        )
        let enriched = TranscriptFormat.renderEpisodeMarkdown(
            showSlug: "s1", title: "t1", srtText: "1\n00:00:00,000 --> 00:00:01,000\nhi\n\n",
            source: "youtube", youtubeID: "abc", pubDate: "2024-01-01",
            now: Date(timeIntervalSince1970: 0),
            extra: [("source_url", "https://youtu.be/abc")]
        )
        for line in baseline.components(separatedBy: "\n") where !line.isEmpty && line != "---" {
            XCTAssertTrue(enriched.contains(line), "baseline line dropped/altered: \(line)")
        }
        XCTAssertTrue(enriched.contains("source_url: https://youtu.be/abc"))
    }
}
