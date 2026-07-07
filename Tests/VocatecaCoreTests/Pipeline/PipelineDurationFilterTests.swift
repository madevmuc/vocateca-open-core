import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - PipelineDurationFilterTests

/// Tests for the episode-length gate at the top of `Pipeline.process(_:)`:
/// an episode whose known `durationSec` falls outside the show's configured
/// `minDurationSec`/`maxDurationSec` must be skipped BEFORE the download
/// phase, and an in-range or unknown-duration episode must proceed normally.
///
/// `Pipeline.process` reads the show via `Watchlist.load(from: Paths.watchlistURL)`
/// (a fixed path, not injectable — mirrors the existing transcribe-phase
/// language-hint lookup), so these tests temporarily install a real
/// `watchlist.yaml` containing the test show and restore whatever was there
/// beforehand in `tearDown`.
final class PipelineDurationFilterTests: XCTestCase {

    // MARK: - Watchlist swap helpers

    private var savedWatchlistData: Data?
    private let watchlistURL = Paths.watchlistURL

    override func tearDown() {
        // Restore whatever watchlist.yaml existed before this test ran (or
        // remove the file entirely if there wasn't one).
        if let savedWatchlistData {
            try? savedWatchlistData.write(to: watchlistURL)
        } else {
            try? FileManager.default.removeItem(at: watchlistURL)
        }
        savedWatchlistData = nil
        super.tearDown()
    }

    /// Installs a single-show watchlist.yaml (backing up any existing file
    /// first) so `Pipeline.process`'s fixed-path show lookup resolves `show`.
    private func installShow(_ show: Show) throws {
        savedWatchlistData = try? Data(contentsOf: watchlistURL)
        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: watchlistURL)
    }

    // MARK: - Helpers

    private func makePipeline(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber = FakeTranscriber(.succeed(PipelineDurationFilterTests.plausibleSpeechResult)),
        ocr: any ImageOCRProcessor = FakeOCRProcessor(),
        writer: any LibraryWriter = FakeLibraryWriter()
    ) -> Pipeline {
        Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: ocr,
            libraryWriter: writer
        )
    }

    /// A transcript with a plausible word count AND varied vocabulary so
    /// `NoSpeechDetector`'s words-per-minute and unique-word-ratio signals
    /// don't fire for the longer durations used in these tests
    /// (`FakeTranscriber.makeDefaultResult()`'s 2-word transcript reads as
    /// "no speech" once paired with a 20+ minute duration).
    private static let plausibleSpeechResult: TranscriptionResult = {
        // 1000 unique words comfortably clears the WPM check even at the
        // longest duration used in these tests (2 h → needs > 360 words).
        let words = (1...1000).map { "word\($0)" }
        return TranscriptionResult(
            text: words.joined(separator: " "),
            segments: [TranscriptionSegment(start: 0, end: 1.0, text: "word1 word2 word3", noSpeechProb: 0.05)],
            language: "en"
        )
    }()

    // MARK: - 1. Below minDurationSec → skipped, no download

    func testEpisodeBelowMinDurationIsSkippedWithoutDownload() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "length-show", title: "Length Show", rss: "https://example.com/rss",
                              minDurationSec: 600, maxDurationSec: 0))

        // 5 minutes — below the 10-minute (600s) minimum.
        let ep = Episode.makePodcast(guid: "short-001", showSlug: "length-show", durationSec: 300)
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/short-001.mp3")))
        let pipeline = makePipeline(store: store, downloader: downloader)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .skipped, "episode shorter than minDurationSec must be skipped")
        XCTAssertEqual(downloader.callCount, 0, "downloader must not be called for a length-filtered episode")

        let saved = try XCTUnwrap(store.episode(guid: "short-001"))
        XCTAssertEqual(saved.status, "skipped")
        XCTAssertNotNil(saved.errorText)

        let events = try store.queryEvents(guid: "short-001")
        let skippedEvents = events.filter { $0["type"] as? String == EventType.episodeSkipped }
        XCTAssertFalse(skippedEvents.isEmpty, "episode.skipped event must be emitted")
    }

    // MARK: - 2. Above maxDurationSec → skipped, no download

    func testEpisodeAboveMaxDurationIsSkippedWithoutDownload() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "length-show", title: "Length Show", rss: "https://example.com/rss",
                              minDurationSec: 0, maxDurationSec: 1800))

        // 45 minutes — above the 30-minute (1800s) maximum.
        let ep = Episode.makePodcast(guid: "long-001", showSlug: "length-show", durationSec: 2700)
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/long-001.mp3")))
        let pipeline = makePipeline(store: store, downloader: downloader)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .skipped, "episode longer than maxDurationSec must be skipped")
        XCTAssertEqual(downloader.callCount, 0, "downloader must not be called for a length-filtered episode")

        let saved = try XCTUnwrap(store.episode(guid: "long-001"))
        XCTAssertEqual(saved.status, "skipped")
    }

    // MARK: - 3. In-range duration → NOT skipped

    func testEpisodeInRangeIsNotSkipped() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "length-show", title: "Length Show", rss: "https://example.com/rss",
                              minDurationSec: 600, maxDurationSec: 1800))

        // 20 minutes — squarely inside [10, 30] minutes.
        let ep = Episode.makePodcast(guid: "inrange-001", showSlug: "length-show", durationSec: 1200)
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/inrange-001.mp3")))
        let pipeline = makePipeline(store: store, downloader: downloader)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done, "in-range episode must proceed through the pipeline")
        XCTAssertEqual(downloader.callCount, 1, "downloader must be called for an in-range episode")
    }

    // MARK: - 4. Unknown duration (nil) → NOT filtered

    func testEpisodeWithUnknownDurationIsNotFiltered() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "length-show", title: "Length Show", rss: "https://example.com/rss",
                              minDurationSec: 600, maxDurationSec: 1800))

        // durationSec is nil — must never be filtered, even though limits are set.
        let ep = Episode.makePodcast(guid: "unknown-001", showSlug: "length-show", durationSec: nil)
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/unknown-001.mp3")))
        let pipeline = makePipeline(store: store, downloader: downloader)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done, "unknown-duration episode must not be filtered")
        XCTAssertEqual(downloader.callCount, 1, "downloader must be called when duration is unknown")
    }

    // MARK: - 5. Both limits 0 (no limit) → behaves exactly as today

    func testNoLimitsConfiguredNeverSkipsOnLength() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try installShow(Show(slug: "length-show", title: "Length Show", rss: "https://example.com/rss",
                              minDurationSec: 0, maxDurationSec: 0))

        // A duration that would be filtered under most real limits — with
        // both bounds at 0 ("no limit") it must still proceed.
        let ep = Episode.makePodcast(guid: "nolimit-001", showSlug: "length-show", durationSec: 7200)
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/nolimit-001.mp3")))
        let pipeline = makePipeline(store: store, downloader: downloader)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done, "0/0 limits must never filter on length")
        XCTAssertEqual(downloader.callCount, 1)
    }
}
