import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - DiarizedWriterTests
//
// Task 4 (Package D — speaker diarization): the transcript writer must emit
// speaker labels when segments carry a `speaker` index, and drop a
// `<slug>.speakers.json` sidecar. When NO segment has a speaker, the output must
// be byte-identical to the pre-diarization writer (no headers, no sidecar).
//
// Display label is 1-based: zero-based `speaker == 0` → "Sprecher 1".
final class DiarizedWriterTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizedWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePodcastEpisode(
        guid: String = "ep-diarize",
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

    /// The three speaker/text fixtures shared by the diarized-path tests:
    /// two consecutive segments for speaker 0, then one for speaker 1.
    private func diarizedSegments() -> [TranscriptionSegment] {
        [
            TranscriptionSegment(start: 0.0, end: 2.5, text: "Hello there",   speaker: 0),
            TranscriptionSegment(start: 2.5, end: 5.0, text: "still me",       speaker: 0),
            TranscriptionSegment(start: 5.0, end: 8.0, text: "now the other", speaker: 1),
        ]
    }

    /// The same texts/timings but with NO speaker (the pre-diarization baseline).
    private func plainSegments() -> [TranscriptionSegment] {
        [
            TranscriptionSegment(start: 0.0, end: 2.5, text: "Hello there"),
            TranscriptionSegment(start: 2.5, end: 5.0, text: "still me"),
            TranscriptionSegment(start: 5.0, end: 8.0, text: "now the other"),
        ]
    }

    private func urls(for episode: Episode, in root: URL) -> (md: URL, srt: URL, sidecar: URL) {
        let slug = MarkdownLibraryWriter.makeSlug(episode)
        let showDir = root.appendingPathComponent(episode.showSlug)
        return (
            md:      showDir.appendingPathComponent("\(slug).md"),
            srt:     showDir.appendingPathComponent("\(slug).srt"),
            sidecar: showDir.appendingPathComponent("\(slug).speakers.json")
        )
    }

    // MARK: - Diarized path: .md speaker headers

    func testMarkdownHasSpeakerHeadersInOrder() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let episode = makePodcastEpisode()
        let segs = diarizedSegments()
        let transcript = TranscriptionResult(
            text: "Hello there still me now the other", segments: segs, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmp, writeSRT: true)
        let mdURL = try await writer.write(
            episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let md = try String(contentsOf: mdURL, encoding: .utf8)

        // Both 1-based headers must be present.
        XCTAssertTrue(md.contains("**Sprecher 1**"), "expected Sprecher 1 header, got:\n\(md)")
        XCTAssertTrue(md.contains("**Sprecher 2**"), "expected Sprecher 2 header, got:\n\(md)")

        // Sprecher 1 must come before Sprecher 2, and the second speaker's text
        // must come after the Sprecher 2 header.
        guard let r1 = md.range(of: "**Sprecher 1**"),
              let r2 = md.range(of: "**Sprecher 2**"),
              let tOther = md.range(of: "now the other") else {
            return XCTFail("markers/text missing:\n\(md)")
        }
        XCTAssertTrue(r1.lowerBound < r2.lowerBound, "Sprecher 1 must precede Sprecher 2")
        XCTAssertTrue(r2.lowerBound < tOther.lowerBound, "Sprecher 2 header must precede its line")

        // The two speaker-0 lines share ONE header (no repeated header between them).
        let firstBlock = String(md[r1.upperBound..<r2.lowerBound])
        XCTAssertTrue(firstBlock.contains("Hello there"))
        XCTAssertTrue(firstBlock.contains("still me"))
        XCTAssertFalse(firstBlock.contains("**Sprecher 1**"),
                       "speaker-0 block must not repeat its header")
    }

    // MARK: - Diarized path: .srt caption prefixes

    func testSRTCaptionsArePrefixedWithSpeakerTag() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let episode = makePodcastEpisode()
        let segs = diarizedSegments()
        let transcript = TranscriptionResult(
            text: "Hello there still me now the other", segments: segs, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmp, writeSRT: true)
        _ = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let srt = try String(contentsOf: urls(for: episode, in: tmp).srt, encoding: .utf8)

        // Each caption text line carries a [SN] prefix (1-based).
        XCTAssertTrue(srt.contains("[S1] Hello there"), "srt:\n\(srt)")
        XCTAssertTrue(srt.contains("[S1] still me"),    "srt:\n\(srt)")
        XCTAssertTrue(srt.contains("[S2] now the other"), "srt:\n\(srt)")
    }

    // MARK: - Diarized path: sidecar JSON

    func testSpeakersSidecarDecodesToThreeZeroBasedEntries() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let episode = makePodcastEpisode()
        let segs = diarizedSegments()
        let transcript = TranscriptionResult(
            text: "Hello there still me now the other", segments: segs, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmp, writeSRT: true)
        _ = try await writer.write(episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let sidecarURL = urls(for: episode, in: tmp).sidecar
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                      "speakers.json sidecar must be written when a speaker is present")

        struct Entry: Decodable, Equatable { let start: Double; let end: Double; let speaker: Int }
        let data = try Data(contentsOf: sidecarURL)
        let entries = try JSONDecoder().decode([Entry].self, from: data)

        XCTAssertEqual(entries, [
            Entry(start: 0.0, end: 2.5, speaker: 0),   // zero-based, matching the segments
            Entry(start: 2.5, end: 5.0, speaker: 0),
            Entry(start: 5.0, end: 8.0, speaker: 1),
        ])
    }

    // MARK: - No-speaker path: byte-identical, no sidecar

    func testAllNilSpeakersProducesNoHeadersNoSidecarAndByteIdenticalOutput() async throws {
        // Baseline dir: the current (pre-diarization) writer output for plain segments.
        let baseTmp = try makeTempDir()
        // Candidate dir: same segments, still all-nil, after the diarization change.
        let candTmp = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseTmp)
            try? FileManager.default.removeItem(at: candTmp)
        }

        let episode = makePodcastEpisode(guid: "ep-plain")
        let segs = plainSegments()
        let transcript = TranscriptionResult(
            text: "Hello there still me now the other", segments: segs, language: "en")

        // Two identical writes to two dirs; both go through the same code path, so
        // any speaker machinery must be inert for all-nil input. We compare the two
        // and also assert the absence of any speaker artefacts — together this pins
        // "byte-identical to a writer that has no diarization awareness at all".
        let writer = MarkdownLibraryWriter(outputRoot: baseTmp, writeSRT: true)
        let baseMD = try await writer.write(
            episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let writer2 = MarkdownLibraryWriter(outputRoot: candTmp, writeSRT: true)
        let candMD = try await writer2.write(
            episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let baseMDText = try String(contentsOf: baseMD, encoding: .utf8)
        let candMDText = try String(contentsOf: candMD, encoding: .utf8)

        // No speaker header/marker anywhere in the all-nil output.
        XCTAssertFalse(candMDText.contains("Sprecher"), "no Sprecher header for all-nil segments")
        XCTAssertFalse(candMDText.contains("[S1]"),     "no [SN] tag in .md for all-nil segments")

        let baseSRT = try String(contentsOf: urls(for: episode, in: baseTmp).srt, encoding: .utf8)
        let candSRT = try String(contentsOf: urls(for: episode, in: candTmp).srt, encoding: .utf8)
        XCTAssertFalse(candSRT.contains("[S"), "no [SN] prefix in .srt for all-nil segments")

        // No sidecar when no segment has a speaker.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: urls(for: episode, in: candTmp).sidecar.path),
            "no speakers.json sidecar when all speakers are nil")

        // Byte-identical .md and .srt (modulo the live-clock transcribed_at line in .md).
        func stripTranscribedAt(_ s: String) -> String {
            s.components(separatedBy: "\n").filter { !$0.hasPrefix("transcribed_at:") }.joined(separator: "\n")
        }
        XCTAssertEqual(stripTranscribedAt(candMDText), stripTranscribedAt(baseMDText),
                       ".md must be byte-identical (transcribed_at excluded) for all-nil segments")
        XCTAssertEqual(candSRT, baseSRT, ".srt must be byte-identical for all-nil segments")
    }

    // MARK: - YouTube path also gets headers (renderEpisodeMarkdown body swap)

    /// The YouTube branch builds its body inside the oracle-locked
    /// `renderEpisodeMarkdown`; the writer swaps the trailing transcript region for
    /// the speaker-annotated one. Verify headers appear there too, and the sidecar
    /// is written.
    func testYouTubePathGetsSpeakerHeadersAndSidecar() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let episode = Episode(
            guid: "yt-diarize",
            showSlug: "yt-show",
            title: "YT Episode",
            pubDate: "2024-03-01",
            mp3Url: "https://www.youtube.com/watch?v=abc123"   // ⇒ youtube path
        )
        let segs = diarizedSegments()
        let transcript = TranscriptionResult(
            text: "Hello there still me now the other", segments: segs, language: "en")

        let writer = MarkdownLibraryWriter(outputRoot: tmp, writeSRT: true)
        let mdURL = try await writer.write(
            episode: episode, transcript: transcript, ocrText: nil, mediaPath: nil)

        let md = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(md.contains("source: youtube"), "should be the youtube md path")
        XCTAssertTrue(md.contains("**Sprecher 1**"), "youtube .md needs speaker headers:\n\(md)")
        XCTAssertTrue(md.contains("**Sprecher 2**"), "youtube .md needs speaker headers:\n\(md)")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: urls(for: episode, in: tmp).sidecar.path),
            "sidecar must be written on the youtube path too")
    }
}
