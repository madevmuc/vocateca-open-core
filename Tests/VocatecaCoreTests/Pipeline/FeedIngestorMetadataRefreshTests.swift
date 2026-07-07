import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - FeedIngestorMetadataRefreshTests

/// Deterministic unit tests for the refresh-metadata fix: a podcast poll now
/// surfaces the feed's channel-level title/author/artwork (parsed from the
/// SAME already-fetched feed bytes used for episode parsing) so callers can
/// persist it via `WatchlistStore.updateMetadata` and replace a slug-derived
/// display name with the real one.
///
/// ## Design
/// We do NOT hit the network (no live-network unit tests). Instead we mirror
/// `FeedIngestorSubscribeTests`:
///  1. Load the committed `Fixtures/feeds/1alage.xml` RSS fixture.
///  2. Run `RSSManifest.parseFeedChannelMeta(fromXML:)` directly — the exact
///     call `FeedIngestor.pollPodcast` now makes on the fetched `data`.
///  3. Map the result into `RefreshedMetadata` (mirrors
///     `IngestCoordinator.persistChannelMetaIfNeeded`) and call
///     `WatchlistStore.updateMetadata` against a temp watchlist file.
///  4. Assert the show's `title`/`artworkUrl` — and therefore `displayName` —
///     flip from the slug to the feed's real title, while `customTitle`
///     (a user's manual rename) is left untouched and still wins.
final class FeedIngestorMetadataRefreshTests: XCTestCase {

    // MARK: - Helpers

    private func load1alageFixture() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "1alage",
            withExtension: "xml",
            subdirectory: "Fixtures/feeds"
        ) else {
            XCTFail("RSS fixture not found: Fixtures/feeds/1alage.xml")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func makeTempWatchlistURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIngestorMetadataRefreshTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("watchlist.yaml")
    }

    /// Mirrors `IngestCoordinator.persistChannelMetaIfNeeded`'s mapping from
    /// `RSSManifest.ChannelMeta` to `RefreshedMetadata` (title + artwork only —
    /// author is parsed/backfilled separately by `pollPodcast`).
    private func refreshedMetadata(from meta: RSSManifest.ChannelMeta) -> RefreshedMetadata {
        RefreshedMetadata(
            title: meta.title.isEmpty ? nil : meta.title,
            author: nil,
            artworkURL: meta.artworkURL.isEmpty ? nil : meta.artworkURL,
            handle: nil
        )
    }

    // MARK: - parseFeedChannelMeta now carries title + artwork

    /// The 1alage fixture has a channel `<title>`, `<itunes:author>`, and both
    /// an `<itunes:image href>` and RSS `<image><url>` — this locks in that
    /// `parseFeedChannelMeta` (extended for this fix) recovers title/artwork
    /// from the same single parse pass used for description/language.
    func testParseFeedChannelMeta_extractsTitleAndArtwork() throws {
        let data = try load1alageFixture()
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: data)

        XCTAssertEqual(meta.title, "1a LAGE - Der Immobilienpodcast")
        XCTAssertFalse(meta.artworkURL.isEmpty, "Expected itunes:image or RSS image to be captured")
        XCTAssertTrue(meta.artworkURL.contains("podigee-cdn.net"),
                      "Expected the podigee CDN artwork URL, got: \(meta.artworkURL)")
        XCTAssertEqual(meta.language, "de")
        XCTAssertFalse(meta.description.isEmpty)
    }

    // MARK: - Slug-title show gets the real title + artwork after "poll"

    /// Simulates the exact bug this fix targets: a show subscribed via
    /// OPML/generic-subscribe/CLI where `Show.title == slug` (no real title
    /// ever fetched). After parsing the already-fetched feed data and
    /// persisting via `updateMetadata` — the plumbing `IngestCoordinator.ingest`
    /// now performs — the show's title flips from the slug to the real feed
    /// title, and `displayName` reflects it.
    func testSlugTitleShow_getsRealTitleAfterMetadataRefresh() throws {
        let wlURL = makeTempWatchlistURL()
        let slug = "1alage-der-immobilienpodcast" // slug == title, simulating the bug

        var show = Show(slug: slug, title: slug, rss: "https://1alage.podigee.io/feed/mp3", source: "podcast")
        show.artworkUrl = "" // no artwork yet either (falls back to initials)

        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: wlURL)

        // Pre-condition: displayName falls through to the slug (the bug).
        XCTAssertEqual(show.displayName, slug)

        // The plumbing under test: parse the already-fetched data, map to
        // RefreshedMetadata, persist via updateMetadata (same call
        // IngestCoordinator.persistChannelMetaIfNeeded makes).
        let data = try load1alageFixture()
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: data)
        let refreshed = refreshedMetadata(from: meta)

        let loaded = try WatchlistStore.load(from: wlURL)
        try loaded.updateMetadata(slug: slug, metadata: refreshed, to: wlURL)

        let after = try WatchlistStore.load(from: wlURL)
        let updatedShow = try XCTUnwrap(after.watchlist.shows.first(where: { $0.slug == slug }))

        XCTAssertEqual(updatedShow.title, "1a LAGE - Der Immobilienpodcast",
                       "title must be replaced with the real feed title, not left as the slug")
        XCTAssertEqual(updatedShow.displayName, "1a LAGE - Der Immobilienpodcast",
                       "displayName must now show the real title instead of falling through to the slug")
        XCTAssertFalse(updatedShow.artworkUrl.isEmpty,
                        "artworkUrl must be populated from the feed so Shows/Library/Queue stop showing initials")
    }

    // MARK: - customTitle (manual rename) survives a metadata refresh

    /// A user's manual rename must never be clobbered by a feed-title refresh:
    /// `displayName` prefers `customTitle` unconditionally, and
    /// `updateMetadata` never writes to `customTitle` at all.
    func testCustomTitle_survivesMetadataRefresh() throws {
        let wlURL = makeTempWatchlistURL()
        let slug = "1alage-der-immobilienpodcast"

        var show = Show(slug: slug, title: slug, rss: "https://1alage.podigee.io/feed/mp3", source: "podcast")
        show.customTitle = "My Renamed Show"

        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: wlURL)

        XCTAssertEqual(show.displayName, "My Renamed Show", "customTitle must win over the slug pre-refresh")

        let data = try load1alageFixture()
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: data)
        let refreshed = refreshedMetadata(from: meta)

        let loaded = try WatchlistStore.load(from: wlURL)
        try loaded.updateMetadata(slug: slug, metadata: refreshed, to: wlURL)

        let after = try WatchlistStore.load(from: wlURL)
        let updatedShow = try XCTUnwrap(after.watchlist.shows.first(where: { $0.slug == slug }))

        XCTAssertEqual(updatedShow.customTitle, "My Renamed Show",
                       "customTitle must be untouched by updateMetadata")
        XCTAssertEqual(updatedShow.title, "1a LAGE - Der Immobilienpodcast",
                       "the underlying feed title is still updated even though customTitle wins display")
        XCTAssertEqual(updatedShow.displayName, "My Renamed Show",
                       "displayName must still prefer customTitle after a metadata refresh")
    }

    // MARK: - Guard: never blank an existing title on an empty/failed parse

    /// A feed with no channel `<title>` at all (empty parse) must never blank
    /// out an existing good title — `updateMetadata`'s applyIfPresent only
    /// overwrites non-empty incoming values.
    func testEmptyChannelMeta_neverBlanksExistingTitle() throws {
        let wlURL = makeTempWatchlistURL()
        let slug = "existing-good-show"

        let show = Show(slug: slug, title: "Existing Good Title", rss: "https://example.com/feed", source: "podcast")
        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: wlURL)

        // A minimal feed with no <title>/<image> at the channel level at all.
        let emptyFeedXML = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><item><title>Ep 1</title></item></channel></rss>
        """.data(using: .utf8)!
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: emptyFeedXML)
        XCTAssertTrue(meta.title.isEmpty, "Precondition: this fixture has no channel-level title")

        let refreshed = refreshedMetadata(from: meta)
        XCTAssertNil(refreshed.title, "nil/empty parse must map to nil — 'don't overwrite'")

        let loaded = try WatchlistStore.load(from: wlURL)
        try loaded.updateMetadata(slug: slug, metadata: refreshed, to: wlURL)

        let after = try WatchlistStore.load(from: wlURL)
        let updatedShow = try XCTUnwrap(after.watchlist.shows.first(where: { $0.slug == slug }))
        XCTAssertEqual(updatedShow.title, "Existing Good Title",
                       "title must be left untouched when the feed parse yields nothing")
    }

    // MARK: - PollResult contract: non-podcast sources carry nil channelMeta

    /// `FeedIngestor.poll` cannot be exercised for the podcast branch without a
    /// live network fetch (`URLSafety.boundedData` enforces a public-host SSRF
    /// check ahead of parsing, so it can't be pointed at a local fixture file).
    /// The podcast parse→persist plumbing itself is covered network-free above
    /// (`testParseFeedChannelMeta_extractsTitleAndArtwork`,
    /// `testSlugTitleShow_getsRealTitleAfterMetadataRefresh`) since it's the
    /// exact `RSSManifest.parseFeedChannelMeta` call `pollPodcast` makes on its
    /// already-fetched `data`.
    ///
    /// This test instead locks in the OTHER half of the `PollResult` contract:
    /// sources that don't yield channel metadata (`local`, and by the same
    /// code path `ytdlp`) must not claim to have any — `poll` either throws
    /// before constructing a `PollResult` (local/unsupported) or returns
    /// `channelMeta == nil` (ytdlp), never a fabricated non-nil value.
    func testPollLocalShow_neverProducesChannelMeta() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIngestorMetadataRefreshTests-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StateStore(databaseURL: dir.appendingPathComponent("state.sqlite"))
        let ingestor = FeedIngestor()

        let localShow = Show(slug: "local-meta-test", title: "Local", rss: "", source: "local")
        do {
            _ = try await ingestor.poll(show: localShow, store: store)
            XCTFail("Expected unsupportedSource for source=local")
        } catch FeedIngestorError.unsupportedSource(let src) {
            XCTAssertEqual(src, "local")
        }

        // ytdlp with an empty rss URL throws before enumeration — same
        // never-fabricate-metadata guarantee, exercised via the public API.
        let ytdlpShow = Show(slug: "ytdlp-meta-test", title: "ytdlp", rss: "", source: "ytdlp")
        do {
            _ = try await ingestor.poll(show: ytdlpShow, store: store)
            XCTFail("Expected an error for empty rss URL")
        } catch FeedIngestorError.unsupportedSource {
            // expected
        } catch FeedIngestorError.fetchFailed {
            // also acceptable — either way, no PollResult with fabricated metadata was returned
        }
    }
}
