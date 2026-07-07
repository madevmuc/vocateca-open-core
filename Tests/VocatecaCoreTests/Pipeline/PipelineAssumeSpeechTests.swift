import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - PipelineAssumeSpeechTests

/// Tests for the per-show music-detection opt-out (`Show.assumeSpeech`) at the
/// no-speech decision point in `Pipeline.process(_:)`.
///
/// The pipeline transcribes the audio, then runs `NoSpeechDetector.classify`.
/// When the show is set to "Always spoken word" (`assumeSpeech == true`, the
/// default) that skip is bypassed entirely — even a transcript the detector
/// would flag as music/instrumental is kept (`.done`). When
/// `assumeSpeech == false` ("Auto-detect / skip music") the detector runs and a
/// music verdict skips the episode (`.skipped`).
///
/// Mirrors `PipelineDurationFilterTests`' watchlist-swap harness: `process`
/// reads the show via `Watchlist.load(from: Paths.watchlistURL)` (a fixed path),
/// so each test installs a real single-show `watchlist.yaml` and restores the
/// prior file in `tearDown`.
final class PipelineAssumeSpeechTests: XCTestCase {

    // MARK: - Watchlist swap helpers

    private var savedWatchlistData: Data?
    private let watchlistURL = Paths.watchlistURL

    override func tearDown() {
        if let savedWatchlistData {
            try? savedWatchlistData.write(to: watchlistURL)
        } else {
            try? FileManager.default.removeItem(at: watchlistURL)
        }
        savedWatchlistData = nil
        super.tearDown()
    }

    private func installShow(_ show: Show) throws {
        savedWatchlistData = try? Data(contentsOf: watchlistURL)
        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: watchlistURL)
    }

    // MARK: - Music-like transcript

    /// A transcript that `NoSpeechDetector` classifies as no-speech via Signal 2
    /// (mean `noSpeechProb` > 0.60) — i.e. what a music/instrumental episode
    /// produces. Independent of duration.
    private static let musicResult: TranscriptionResult = TranscriptionResult(
        text: "la la la",
        segments: [TranscriptionSegment(start: 0, end: 1.0, text: "la la la", noSpeechProb: 0.95)],
        language: "en"
    )

    private func makePipeline(store: StateStore) -> Pipeline {
        Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/assumespeech.mp3"))),
            transcriber: FakeTranscriber(.succeed(PipelineAssumeSpeechTests.musicResult)),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter()
        )
    }

    // Sanity: the detector really does flag this transcript as no-speech, so a
    // `.done` result below can only be the assumeSpeech bypass, not a weak fixture.
    func testMusicFixtureIsClassifiedAsNoSpeech() {
        let verdict = NoSpeechDetector.classify(Self.musicResult, durationSec: 120)
        XCTAssertTrue(verdict.isNoSpeech,
                      "fixture must read as no-speech for the bypass test to be meaningful")
    }

    // MARK: - assumeSpeech == true (default) → NOT skipped

    func testAssumeSpeechTrueTranscribesMusicWithoutSkipping() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "speech-show", title: "Speech Show",
                             rss: "https://example.com/rss", assumeSpeech: true))

        let ep = Episode.makePodcast(guid: "music-001", showSlug: "speech-show", durationSec: 120)
        try store.upsert(ep)

        let result = await makePipeline(store: store).process(ep)

        XCTAssertEqual(result.finalStatus, .done,
                       "assumeSpeech=true must transcribe a music-flagged episode, never skip it")

        let saved = try XCTUnwrap(store.episode(guid: "music-001"))
        XCTAssertEqual(saved.status, "done")

        // No skipped event may be emitted for an assumeSpeech show.
        let events = try store.queryEvents(guid: "music-001")
        let skippedEvents = events.filter { $0["type"] as? String == EventType.episodeSkipped }
        XCTAssertTrue(skippedEvents.isEmpty,
                      "assumeSpeech=true must not emit a skipped/no-speech event")
    }

    // MARK: - assumeSpeech == false → skipped as music

    func testAssumeSpeechFalseSkipsMusic() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "auto-show", title: "Auto Show",
                             rss: "https://example.com/rss", assumeSpeech: false))

        let ep = Episode.makePodcast(guid: "music-002", showSlug: "auto-show", durationSec: 120)
        try store.upsert(ep)

        let result = await makePipeline(store: store).process(ep)

        XCTAssertEqual(result.finalStatus, .skipped,
                       "assumeSpeech=false must let the no-speech detector skip a music episode")

        let saved = try XCTUnwrap(store.episode(guid: "music-002"))
        XCTAssertEqual(saved.status, "skipped")
        XCTAssertNotNil(saved.errorText)

        let events = try store.queryEvents(guid: "music-002")
        let skippedEvents = events.filter { $0["type"] as? String == EventType.episodeSkipped }
        XCTAssertFalse(skippedEvents.isEmpty,
                       "assumeSpeech=false must emit a skipped/no-speech event")
    }
}
