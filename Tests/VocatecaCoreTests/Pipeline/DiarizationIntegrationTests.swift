import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - DiarizationIntegrationTests

/// End-to-end proof that the diarization stage is wired into the transcription
/// pipeline (Package D, Task 5): a fake `Diarizer` returns two speaker spans,
/// and — when `settings.diarizationEnabled` is true — the written `.md` gains
/// bold `**Sprecher 1**`/`**Sprecher 2**` headers and a `<slug>.speakers.json`
/// sidecar lands next to it. With the setting off (or no diarizer injected)
/// neither appears, and a THROWING diarizer degrades cleanly to a valid
/// speaker-free transcript (diarization must never fail transcription).
///
/// Harness mirrors `TranscriptCorrectionIntegrationTests`: `Pipeline.process`
/// reads the show via `Watchlist.load(from: Paths.watchlistURL)` and the
/// settings via `SettingsStore.load(from: Paths.settingsURL)` — both fixed
/// paths — so each test installs a real single-show `watchlist.yaml` and a
/// real `settings.yaml`, restoring the prior files in `tearDown`. The **real**
/// `MarkdownLibraryWriter` writes an actual `.md`/sidecar into a temp dir so
/// the assertions read the true on-disk output.
final class DiarizationIntegrationTests: XCTestCase {

    // MARK: - File-swap helpers

    private var savedWatchlistData: Data?
    private var savedSettingsData: Data?
    private let watchlistURL = Paths.watchlistURL
    private let settingsURL = Paths.settingsURL

    override func tearDown() {
        restore(savedWatchlistData, to: watchlistURL)
        restore(savedSettingsData, to: settingsURL)
        savedWatchlistData = nil
        savedSettingsData = nil
        super.tearDown()
    }

    private func restore(_ data: Data?, to url: URL) {
        if let data {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func installShow(_ show: Show) throws {
        savedWatchlistData = try? Data(contentsOf: watchlistURL)
        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: watchlistURL)
    }

    /// Installs a `settings.yaml` with diarization on/off. Proper-noun correction
    /// is forced `off` so the corrector never rewrites the fixture text — the only
    /// variable under test is the diarization gate.
    private func installSettings(diarization: Bool) throws {
        savedSettingsData = try? Data(contentsOf: settingsURL)
        var settings = Settings()
        settings.properNounCorrection = "off"
        settings.diarizationEnabled = diarization
        try SettingsStore.save(settings, to: settingsURL)
    }

    // MARK: - Fakes

    /// A fake `Diarizer` returning a fixed two-speaker split of a 6 s clip:
    /// speaker 0 owns [0,3), speaker 1 owns [3,6). Ignores the audio URL entirely
    /// (no real file needed on disk).
    private struct FakeDiarizer: Diarizer {
        func diarize(audioURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerSegment] {
            progress?(1.0)
            return [
                SpeakerSegment(speaker: 0, start: 0, end: 3),
                SpeakerSegment(speaker: 1, start: 3, end: 6),
            ]
        }
    }

    /// A fake `Diarizer` that always throws — models a model-load / decode failure.
    /// The pipeline must log it and still write a valid speaker-free transcript.
    private struct ThrowingDiarizer: Diarizer {
        struct Boom: Error {}
        func diarize(audioURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerSegment] {
            throw Boom()
        }
    }

    /// Two ASR segments straddling the speaker boundary at 3 s: the first lands in
    /// speaker 0, the second in speaker 1.
    private static func twoSpeakerResult() -> TranscriptionResult {
        TranscriptionResult(
            text: "Hallo, ich bin der erste Sprecher. Und ich bin der zweite.",
            segments: [
                TranscriptionSegment(start: 0, end: 2.8,
                                     text: "Hallo, ich bin der erste Sprecher.",
                                     noSpeechProb: 0.0, avgLogprob: -0.1),
                TranscriptionSegment(start: 3.2, end: 5.8,
                                     text: "Und ich bin der zweite.",
                                     noSpeechProb: 0.0, avgLogprob: -0.1),
            ],
            language: "de"
        )
    }

    private func makePipeline(store: StateStore, outputRoot: URL, diarizer: (any Diarizer)?) -> Pipeline {
        Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/diarize.mp3"))),
            transcriber: FakeTranscriber(.succeed(Self.twoSpeakerResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: MarkdownLibraryWriter(outputRoot: outputRoot, writeSRT: true),
            diarizer: diarizer
        )
    }

    // Slug is brand-free; assumeSpeech avoids the no-speech skip for the short clip.
    private func diarShow() -> Show {
        Show(slug: "diar-show",
             title: "Diarization Test Show",
             rss: "https://example.com/rss",
             assumeSpeech: true)
    }

    /// The `<slug>.speakers.json` sidecar path derived from the written `.md` path —
    /// the writer names both from the EPISODE slug (`<episodeSlug>.md` /
    /// `<episodeSlug>.speakers.json`) in the show dir, so we transform the `.md`
    /// path rather than hard-coding a name.
    private func sidecarURL(forMarkdown mdPath: String) -> URL {
        let md = URL(fileURLWithPath: mdPath)
        let base = md.deletingPathExtension().lastPathComponent   // strip ".md"
        return md.deletingLastPathComponent()
            .appendingPathComponent("\(base).speakers.json")
    }

    // MARK: - diarizationEnabled == true → speaker labels + sidecar

    func testDiarizationEnabledWritesSpeakerLabelsAndSidecar() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(diarShow())
        try installSettings(diarization: true)

        let ep = Episode.makePodcast(guid: "diar-001", showSlug: "diar-show",
                                     title: "Episode with two speakers", durationSec: 6)
        try store.upsert(ep)

        let result = await makePipeline(store: store, outputRoot: outputRoot,
                                        diarizer: FakeDiarizer()).process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        XCTAssertTrue(md.contains("**Sprecher 1**"),
                      "diarized .md must carry the 1-based speaker-0 header\n\(md)")
        XCTAssertTrue(md.contains("**Sprecher 2**"),
                      "diarized .md must carry the 1-based speaker-1 header\n\(md)")

        // Sidecar next to the .md: <slug>.speakers.json.
        let sidecar = sidecarURL(forMarkdown: mdPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                      "a <slug>.speakers.json sidecar must exist at \(sidecar.path)")
    }

    // MARK: - diarizationEnabled == false → no labels, no sidecar

    func testDiarizationDisabledWritesNoSpeakerLabels() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(diarShow())
        try installSettings(diarization: false)

        let ep = Episode.makePodcast(guid: "diar-002", showSlug: "diar-show",
                                     title: "Episode with two speakers", durationSec: 6)
        try store.upsert(ep)

        // Diarizer IS injected, but the setting gates it off — proving the gate,
        // not the absence of an engine.
        let result = await makePipeline(store: store, outputRoot: outputRoot,
                                        diarizer: FakeDiarizer()).process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        XCTAssertFalse(md.contains("**Sprecher 1**"),
                       "with diarization off, no speaker header must appear\n\(md)")

        let sidecar = sidecarURL(forMarkdown: mdPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "with diarization off, no sidecar must be written")
    }

    // MARK: - diarizer == nil → no labels, no sidecar (even with setting on)

    func testNilDiarizerWritesNoSpeakerLabels() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(diarShow())
        try installSettings(diarization: true)

        let ep = Episode.makePodcast(guid: "diar-003", showSlug: "diar-show",
                                     title: "Episode with two speakers", durationSec: 6)
        try store.upsert(ep)

        // Setting is ON but NO diarizer is injected (tests/preview path).
        let result = await makePipeline(store: store, outputRoot: outputRoot,
                                        diarizer: nil).process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        XCTAssertFalse(md.contains("**Sprecher 1**"),
                       "with no diarizer injected, no speaker header must appear\n\(md)")

        let sidecar = sidecarURL(forMarkdown: mdPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "with no diarizer injected, no sidecar must be written")
    }

    // MARK: - throwing diarizer → graceful fallback (valid speaker-free transcript)

    func testThrowingDiarizerFallsBackToSpeakerFreeTranscript() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(diarShow())
        try installSettings(diarization: true)

        let ep = Episode.makePodcast(guid: "diar-004", showSlug: "diar-show",
                                     title: "Episode with two speakers", durationSec: 6)
        try store.upsert(ep)

        let result = await makePipeline(store: store, outputRoot: outputRoot,
                                        diarizer: ThrowingDiarizer()).process(ep)
        // Diarization failure must NOT fail the transcription — episode is still done.
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        // The transcript body is intact…
        XCTAssertTrue(md.contains("Hallo, ich bin der erste Sprecher."),
                      "the transcript text must survive a diarizer failure\n\(md)")
        // …but carries no speaker header and no sidecar.
        XCTAssertFalse(md.contains("**Sprecher 1**"),
                       "a diarizer failure must degrade to a speaker-free transcript\n\(md)")

        let sidecar = sidecarURL(forMarkdown: mdPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "a diarizer failure must not leave a sidecar")
    }
}
