import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - WatchlistStoreTests

/// Unit tests for ``WatchlistStore``.
///
/// Every test that touches the filesystem uses a fresh temp directory that is
/// removed in its `defer` block, matching the pattern from ``StateStoreTests``.
final class WatchlistStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Create a fresh temporary directory and return its URL.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchlistStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A URL inside `dir` named `watchlist.yaml`.
    private func watchlistURL(in dir: URL) -> URL {
        dir.appendingPathComponent("watchlist.yaml")
    }

    /// Minimal valid ``Show`` for use in tests.
    private func makeShow(slug: String = "test-show",
                          title: String = "Test Show",
                          rss: String = "https://example.com/feed.xml") -> Show {
        Show(slug: slug, title: title, rss: rss)
    }

    // MARK: - load-missing returns empty

    func testLoadMissingFileReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        // File does not exist — must not throw, must return empty.
        let store = try WatchlistStore.load(from: url)
        XCTAssertTrue(store.watchlist.shows.isEmpty,
            "load from missing file should return an empty watchlist")
    }

    // MARK: - add then save then reload

    func testAddSaveReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = makeShow()
        let wasNew = store.add(show)
        XCTAssertTrue(wasNew, "first add of a new show must return true")
        XCTAssertEqual(store.watchlist.shows.count, 1)

        // `add` stamps `addedAt` on a fresh insert (sentinel → today), so compare
        // the reload against the STORED show, not the pre-add original.
        let stored = try XCTUnwrap(store.watchlist.shows.first)
        XCTAssertNotEqual(stored.addedAt, Show.defaultAddedAt,
            "add must stamp addedAt away from the sentinel on a new insert")

        try store.save(to: url)

        // Reload from disk.
        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 1)
        XCTAssertEqual(store2.watchlist.shows.first, stored,
            "round-tripped show must be Equatable-equal to the stored (post-add) show")
    }

    // MARK: - dedup on re-add (same slug)

    func testAddDedupBySlug() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = makeShow()
        store.add(show)

        // Re-add the same slug with a changed title — should update, not append.
        var updated = show
        updated.title = "Updated Title"
        let wasNew = store.add(updated)

        XCTAssertFalse(wasNew, "re-adding a show with the same slug must return false")
        XCTAssertEqual(store.watchlist.shows.count, 1,
            "watchlist must still have exactly 1 show after re-add")
        XCTAssertEqual(store.watchlist.shows.first?.title, "Updated Title",
            "existing show must be updated in place")

        // Round-trip to confirm the update survives serialisation.
        try store.save(to: url)
        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 1)
        XCTAssertEqual(store2.watchlist.shows.first?.title, "Updated Title")
    }

    // MARK: - dedup on re-add (same RSS URL, different slug)

    func testAddDedupByRSSURL() throws {
        let store = WatchlistStore()
        let show1 = makeShow(slug: "slug-one", title: "Show One", rss: "https://example.com/same.xml")
        store.add(show1)

        // Different slug, same rss — should update, not append.
        let show2 = makeShow(slug: "slug-two", title: "Show Two", rss: "https://example.com/same.xml")
        let wasNew = store.add(show2)

        XCTAssertFalse(wasNew, "same rss URL with different slug must not append a new show")
        XCTAssertEqual(store.watchlist.shows.count, 1)
    }

    // MARK: - add multiple distinct shows

    func testAddMultipleShows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let a = makeShow(slug: "alpha", title: "Alpha", rss: "https://a.example.com/feed.xml")
        let b = makeShow(slug: "beta",  title: "Beta",  rss: "https://b.example.com/feed.xml")
        let c = makeShow(slug: "gamma", title: "Gamma", rss: "https://c.example.com/feed.xml")
        store.add(a)
        store.add(b)
        store.add(c)

        XCTAssertEqual(store.watchlist.shows.count, 3)

        try store.save(to: url)
        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 3)
        let slugs = store2.watchlist.shows.map(\.slug)
        XCTAssertTrue(slugs.contains("alpha"))
        XCTAssertTrue(slugs.contains("beta"))
        XCTAssertTrue(slugs.contains("gamma"))
    }

    // MARK: - remove

    func testRemoveBySlug() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let a = makeShow(slug: "keep",   title: "Keep",   rss: "https://keep.example.com/feed.xml")
        let b = makeShow(slug: "remove", title: "Remove", rss: "https://remove.example.com/feed.xml")
        store.add(a)
        store.add(b)
        XCTAssertEqual(store.watchlist.shows.count, 2)

        store.remove(slug: "remove")
        XCTAssertEqual(store.watchlist.shows.count, 1)
        XCTAssertEqual(store.watchlist.shows.first?.slug, "keep")

        // Persist and reload — removed show must stay gone.
        try store.save(to: url)
        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 1)
        XCTAssertEqual(store2.watchlist.shows.first?.slug, "keep")
    }

    func testRemoveNonExistentSlugIsNoOp() {
        let store = WatchlistStore()
        store.add(makeShow())
        XCTAssertEqual(store.watchlist.shows.count, 1)

        // Should not crash or change the count.
        store.remove(slug: "does-not-exist")
        XCTAssertEqual(store.watchlist.shows.count, 1)
    }

    // MARK: - addPodcast convenience

    func testAddPodcastProducesLoadableShow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()

        try store.addPodcast(
            feedURL: "https://podcast.example.com/rss",
            title: "My Favourite Podcast",
            author: "Jane Doe",
            artworkURL: "https://artwork.example.com/cover.jpg",
            to: url
        )

        // File must exist on disk after addPodcast.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "addPodcast must write the file to disk")

        // Reload and verify the show is present and well-formed.
        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 1)

        let show = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(show.slug, "my-favourite-podcast",
            "slug must be derived from title")
        XCTAssertEqual(show.title, "My Favourite Podcast")
        XCTAssertEqual(show.rss, "https://podcast.example.com/rss")
        XCTAssertEqual(show.artworkUrl, "https://artwork.example.com/cover.jpg")
        XCTAssertEqual(show.source, "podcast")
        // All defaulted fields must be at their Show defaults.
        XCTAssertEqual(show.enabled, Show.defaultEnabled)
        XCTAssertEqual(show.language, Show.defaultLanguage)
        XCTAssertEqual(show.notify,   Show.defaultNotify)
    }

    func testAddPodcastWithoutArtworkUsesEmptyString() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        try store.addPodcast(feedURL: "https://feed.example.com/rss",
                             title: "No Artwork Podcast",
                             author: "Someone",
                             to: url)

        let store2 = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(show.artworkUrl, "",
            "missing artworkURL must fall back to the empty-string default")
    }

    // MARK: - addPodcast dedup: calling twice with the same feed URL updates in place

    func testAddPodcastDedupOnReAdd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()

        try store.addPodcast(feedURL: "https://same.example.com/rss",
                             title: "Same Feed",
                             author: "A",
                             to: url)
        try store.addPodcast(feedURL: "https://same.example.com/rss",
                             title: "Same Feed",
                             author: "B",
                             to: url)

        XCTAssertEqual(store.watchlist.shows.count, 1,
            "addPodcast with the same feedURL must not duplicate the show")
    }

    // MARK: - Atomic write leaves no .tmp file behind

    func testAtomicSaveLeavesNoTmpFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        store.add(makeShow())
        try store.save(to: url)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tmpFiles = contents.filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(tmpFiles.isEmpty,
            "atomic save must leave no .tmp files behind; found: \(tmpFiles)")
    }

    // MARK: - Slugify helper

    func testSlugify() {
        XCTAssertEqual(WatchlistStore.slugify("My Favourite Podcast"), "my-favourite-podcast")
        XCTAssertEqual(WatchlistStore.slugify("Hello, World!"),        "hello-world")
        XCTAssertEqual(WatchlistStore.slugify("Söhne Mannheims"),      "söhne-mannheims")
        XCTAssertEqual(WatchlistStore.slugify("  leading spaces  "),   "leading-spaces")
        XCTAssertEqual(WatchlistStore.slugify("---"),                  "show",
            "all-symbol title must fall back to 'show'")
        XCTAssertEqual(WatchlistStore.slugify(""),                     "show",
            "empty title must fall back to 'show'")
        XCTAssertEqual(WatchlistStore.slugify("The Daily"),            "the-daily")
        XCTAssertEqual(WatchlistStore.slugify("99% Invisible"),        "99-invisible")
    }

    // MARK: - addPodcast with URL host as title (direct-URL flow in AddSourceSheet)

    /// Verifies the exact path taken by AddSourceSheet.addDirectURL:
    ///   let host = URL(string: url)?.host ?? url
    ///   store.addPodcast(feedURL: url, title: host, ...)
    /// The resulting slug should be derived from the host.
    func testAddPodcastDirectURLHostAsTitle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let feedURL = "https://feeds.relay.fm/cortex"
        let host = URL(string: feedURL)?.host ?? feedURL

        XCTAssertEqual(host, "feeds.relay.fm",
            "URL(string:)?.host must extract the host component")

        let store = WatchlistStore()
        try store.addPodcast(feedURL: feedURL, title: host, author: "", to: url)

        let store2 = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(show.rss, feedURL)
        XCTAssertEqual(show.title, "feeds.relay.fm")
        XCTAssertEqual(show.slug, "feeds-relay-fm",
            "slug derived from URL host must replace dots with hyphens")
    }

    // MARK: - updateMetadata

    func testUpdateMetadata_overwrites_artworkUrl_when_provided() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = Show(
            slug: "test-podcast",
            title: "Test Podcast",
            rss: "https://example.com/feed.xml",
            artworkUrl: "https://old.example.com/art.jpg",
            source: "podcast"
        )
        store.add(show)
        try store.save(to: url)

        let meta = RefreshedMetadata(
            title: nil,
            author: "New Author",
            artworkURL: "https://new.example.com/art.jpg",
            handle: nil
        )
        try store.updateMetadata(slug: "test-podcast", metadata: meta, to: url)

        let store2 = try WatchlistStore.load(from: url)
        let updated = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(updated.artworkUrl, "https://new.example.com/art.jpg",
            "updateMetadata must overwrite artworkUrl when non-nil and non-empty")
        XCTAssertEqual(updated.author, "New Author")
        XCTAssertEqual(updated.title, "Test Podcast",
            "title must be preserved when incoming title is nil")
    }

    func testUpdateMetadata_preserves_existing_when_incoming_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = Show(
            slug: "test-podcast",
            title: "Existing Title",
            rss: "https://example.com/feed.xml",
            artworkUrl: "https://existing.example.com/art.jpg",
            source: "podcast",
            author: "Existing Author"
        )
        store.add(show)
        try store.save(to: url)

        // Incoming empty string — should NOT overwrite
        let meta = RefreshedMetadata(
            title: "",
            author: "",
            artworkURL: "",
            handle: nil
        )
        try store.updateMetadata(slug: "test-podcast", metadata: meta, to: url)

        let store2 = try WatchlistStore.load(from: url)
        let updated = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(updated.title, "Existing Title",
            "empty incoming title must not overwrite existing title")
        XCTAssertEqual(updated.author, "Existing Author",
            "empty incoming author must not overwrite existing author")
        XCTAssertEqual(updated.artworkUrl, "https://existing.example.com/art.jpg",
            "empty incoming artworkURL must not overwrite existing artworkUrl")
    }

    func testUpdateMetadata_preserves_existing_when_incoming_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = Show(
            slug: "test-show",
            title: "Existing Title",
            rss: "https://example.com/feed.xml",
            artworkUrl: "https://existing.example.com/art.jpg",
            source: "podcast"
        )
        store.add(show)
        try store.save(to: url)

        // All nil — nothing should change
        let meta = RefreshedMetadata(title: nil, author: nil, artworkURL: nil, handle: nil)
        try store.updateMetadata(slug: "test-show", metadata: meta, to: url)

        let store2 = try WatchlistStore.load(from: url)
        let updated = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(updated.title, "Existing Title")
        XCTAssertEqual(updated.artworkUrl, "https://existing.example.com/art.jpg")
    }

    func testUpdateMetadata_handle_used_as_author_when_author_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = Show(
            slug: "ig-show",
            title: "IG Show",
            rss: "https://www.instagram.com/coolcreator",
            source: "instagram"
        )
        store.add(show)
        try store.save(to: url)

        let meta = RefreshedMetadata(title: "coolcreator", author: nil, artworkURL: nil, handle: "coolcreator")
        try store.updateMetadata(slug: "ig-show", metadata: meta, to: url)

        let store2 = try WatchlistStore.load(from: url)
        let updated = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(updated.author, "coolcreator",
            "when author is nil/empty and handle is provided, handle is used as author")
    }

    func testUpdateMetadata_noOp_for_unknown_slug() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        store.add(makeShow(slug: "existing"))
        try store.save(to: url)

        let meta = RefreshedMetadata(
            title: "New Title",
            author: "New Author",
            artworkURL: "https://example.com/new.jpg",
            handle: nil
        )
        // Unknown slug — should not throw, should not change anything
        try store.updateMetadata(slug: "does-not-exist", metadata: meta, to: url)

        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.first?.slug, "existing",
            "updateMetadata on unknown slug must not modify other shows")
    }

    // MARK: - addInstagram convenience

    /// Handle with @ prefix normalises to the same slug as one without.
    func testAddInstagramHandleNormalisesAtSign() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()

        let showWith = try store.addInstagram(
            handle: "@mkbhd",
            reels: true, posts: false, stories: true,
            backfillMode: "forward", backfillN: 0,
            to: url
        )

        // Clear store for second call
        let store2 = WatchlistStore()
        let showWithout = try store2.addInstagram(
            handle: "mkbhd",
            reels: true, posts: false, stories: true,
            backfillMode: "forward", backfillN: 0,
            to: url
        )

        XCTAssertEqual(showWith.slug, showWithout.slug,
            "handle with @ and without must produce the same slug")
        XCTAssertEqual(showWith.slug, "mkbhd")
    }

    /// Source is "instagram", rss is "", artworkUrl is "".
    func testAddInstagramSourceAndRssAndArtwork() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        let show = try store.addInstagram(
            handle: "coolcreator",
            reels: true, posts: true, stories: false,
            backfillMode: "last_n", backfillN: 30,
            to: url
        )

        XCTAssertEqual(show.source, "instagram",
            "source must be 'instagram'")
        XCTAssertEqual(show.rss, "",
            "rss must be empty string for Instagram (no RSS feed)")
        XCTAssertEqual(show.artworkUrl, "",
            "artworkUrl must be empty string (no live avatar fetch in this wave)")
    }

    /// Toggle and backfill values are persisted and round-trip through YAML.
    func testAddInstagramTogglesAndBackfillRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        _ = try store.addInstagram(
            handle: "techreviewer",
            reels: false, posts: true, stories: true,
            backfillMode: "full", backfillN: 0,
            to: url
        )

        let store2 = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(store2.watchlist.shows.first)

        XCTAssertFalse(show.igReels,  "igReels must be persisted as false")
        XCTAssertTrue(show.igPosts,   "igPosts must be persisted as true")
        XCTAssertTrue(show.igStories, "igStories must be persisted as true")
        XCTAssertEqual(show.igBackfillMode, "full", "igBackfillMode must be persisted")
        XCTAssertEqual(show.igBackfillN,    0,       "igBackfillN must be persisted")
    }

    /// Adding the same handle twice (with and without @) dedupes to one show.
    func testAddInstagramDedupOnReAdd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        _ = try store.addInstagram(
            handle: "@natgeo",
            reels: true, posts: true, stories: false,
            backfillMode: "forward", backfillN: 0,
            to: url
        )
        _ = try store.addInstagram(
            handle: "natgeo",
            reels: false, posts: false, stories: true,
            backfillMode: "last_n", backfillN: 10,
            to: url
        )

        XCTAssertEqual(store.watchlist.shows.count, 1,
            "addInstagram called twice with the same handle must not append a duplicate")
        // The second call should have updated in place.
        let show = try XCTUnwrap(store.watchlist.shows.first)
        XCTAssertFalse(show.igReels,  "re-add must update igReels to the new value")
        XCTAssertEqual(show.igBackfillMode, "last_n", "re-add must update backfillMode")
    }

    /// YAML round-trip preserves the show at load time.
    func testAddInstagramSavingAndReloadRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        _ = try store.addInstagram(
            handle: "@photography",
            reels: true, posts: false, stories: false,
            backfillMode: "last_n", backfillN: 50,
            to: url
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "addInstagram must write the watchlist to disk")

        let store2 = try WatchlistStore.load(from: url)
        XCTAssertEqual(store2.watchlist.shows.count, 1)

        let show = try XCTUnwrap(store2.watchlist.shows.first)
        XCTAssertEqual(show.slug,           "photography")
        XCTAssertEqual(show.title,          "@photography")
        XCTAssertEqual(show.author,         "@photography")
        XCTAssertEqual(show.source,         "instagram")
        XCTAssertEqual(show.rss,            "")
        XCTAssertEqual(show.artworkUrl,     "")
        XCTAssertTrue(show.igReels)
        XCTAssertFalse(show.igPosts)
        XCTAssertFalse(show.igStories)
        XCTAssertEqual(show.igBackfillMode, "last_n")
        XCTAssertEqual(show.igBackfillN,    50)
    }

    // MARK: - Empty watchlist round-trips correctly

    func testEmptyWatchlistRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = watchlistURL(in: dir)
        let store = WatchlistStore()
        try store.save(to: url)

        let store2 = try WatchlistStore.load(from: url)
        XCTAssertTrue(store2.watchlist.shows.isEmpty,
            "saving and reloading an empty watchlist must still give an empty watchlist")
    }

    // MARK: - reconnectShow (Repair tool — orphaned-show reconnect primitive)

    /// A fixture RSS feed whose channel title/artwork are NOT slug-shaped —
    /// verifies `reconnectShow` binds the feed to the caller-supplied slug
    /// VERBATIM, never re-deriving it via `slugify(title)`. This is the whole
    /// point of the primitive: the orphaned show's existing DB episodes are
    /// keyed to the ORIGINAL slug, so title-derived re-slugging would silently
    /// orphan them again under a new slug.
    private static let fixtureFeedXML = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>The Reconnected Show!</title>
        <itunes:image href="https://example.com/reconnected-artwork.jpg"/>
        <itunes:author>Jane Host</itunes:author>
        <item><title>Episode 1</title><guid>ep-1</guid></item>
      </channel>
    </rss>
    """

    func testReconnectShow_bindsFixtureFeedMetaToExactSlugVerbatim() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        // The orphaned slug, as it exists in state.sqlite — deliberately NOT what
        // `slugify(title)` of the fixture's channel title would produce, so a
        // regression that re-derives the slug from the parsed title is caught.
        let orphanSlug = "show-slug-from-old-import-run-7f3a"

        // Parse the fixture feed exactly the way the Repair tool's fetch glue
        // does (RepairFeedMetadataFetcher → RSSManifest.parseFeedChannelMeta).
        let data = Self.fixtureFeedXML.data(using: .utf8)!
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: data)
        XCTAssertEqual(meta.title, "The Reconnected Show!")
        XCTAssertEqual(meta.artworkURL, "https://example.com/reconnected-artwork.jpg")

        let store = WatchlistStore()
        try store.reconnectShow(
            slug: orphanSlug,
            rss: "https://example.com/feed.xml",
            title: meta.title,
            author: nil,
            artworkURL: meta.artworkURL,
            to: url
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "reconnectShow must persist the watchlist")

        let reloaded = try WatchlistStore.load(from: url)
        XCTAssertEqual(reloaded.watchlist.shows.count, 1)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first)

        // The slug must be EXACTLY the orphaned slug — never re-derived from the
        // parsed title (which would slugify to something like
        // "the-reconnected-show" and silently orphan the episodes again).
        XCTAssertEqual(show.slug, orphanSlug)
        XCTAssertNotEqual(show.slug, WatchlistStore.slugify(meta.title),
            "the reconnected slug must differ from slugify(title) in this fixture — proves verbatim binding, not re-derivation")
        XCTAssertEqual(show.title, meta.title)
        XCTAssertEqual(show.rss, "https://example.com/feed.xml")
        XCTAssertEqual(show.artworkUrl, meta.artworkURL)
        XCTAssertEqual(show.source, "podcast")
    }

    func testReconnectShow_emptyTitleFallsBackToSlug() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        let store = WatchlistStore()
        try store.reconnectShow(slug: "orphan-empty-title", rss: "https://example.com/feed.xml", title: "", to: url)

        let reloaded = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first)
        XCTAssertEqual(show.title, "orphan-empty-title",
            "an empty parsed title must fall back to the slug, never a blank display name")
    }

    func testReconnectShow_updatesExistingEntryInPlace_doesNotDuplicate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        let store = WatchlistStore()
        try store.reconnectShow(slug: "already-reconnected", rss: "https://old.example.com/feed.xml", title: "Old Title", to: url)
        try store.reconnectShow(slug: "already-reconnected", rss: "https://new.example.com/feed.xml", title: "New Title", to: url)

        let reloaded = try WatchlistStore.load(from: url)
        XCTAssertEqual(reloaded.watchlist.shows.count, 1,
            "reconnecting the same slug twice must update in place, never duplicate")
        let show = try XCTUnwrap(reloaded.watchlist.shows.first)
        XCTAssertEqual(show.title, "New Title")
        XCTAssertEqual(show.rss, "https://new.example.com/feed.xml")
    }

    // MARK: - M9: concurrent read-modify-write race

    /// Regression coverage for M9's actual race: two independent callers each
    /// `WatchlistStore.load()` their OWN snapshot of the SAME file, mutate a
    /// DIFFERENT field on the SAME show, and save — mirroring
    /// `FeedIngestor`'s author-backfill racing `IngestCoordinator`'s
    /// metadata-refresh (`updateAuthor` vs `updateMetadata`, both entered via
    /// a fresh `WatchlistStore.load(from:)` per the real call sites).
    ///
    /// Before the fix: `save(to:)` blindly serialised each caller's own
    /// (increasingly stale) in-memory `Watchlist`, so whichever save ran
    /// SECOND clobbered the first caller's field with its own, older
    /// snapshot's value — one edit silently vanished with no error.
    ///
    /// After the fix: every mutator re-reads the freshest on-disk copy
    /// immediately before merging its own field change, inside one
    /// `NSFileCoordinator`-serialised transaction — so BOTH concurrent
    /// edits land regardless of interleaving or ordering.
    func testConcurrentUpdatesToDifferentFieldsBothSurvive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        // Seed the show both "writers" will race to update.
        let seedStore = WatchlistStore()
        seedStore.add(makeShow(slug: "race-show", title: "Race Show"))
        try seedStore.save(to: url)

        // Writer A: mirrors FeedIngestor's author-backfill — load fresh, set author.
        // Writer B: mirrors IngestCoordinator's metadata-refresh — load fresh, set language.
        // Run truly concurrently via a task group so their `load()`s can race.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let store = try WatchlistStore.load(from: url)
                try store.updateAuthor(slug: "race-show", author: "Writer A Author", to: url)
            }
            group.addTask {
                let store = try WatchlistStore.load(from: url)
                try store.updateLanguage(slug: "race-show", language: "de", to: url)
            }
            try await group.waitForAll()
        }

        let final = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(final.watchlist.shows.first(where: { $0.slug == "race-show" }))
        XCTAssertEqual(show.author, "Writer A Author",
            "Writer A's author edit must survive concurrent with Writer B's language edit")
        XCTAssertEqual(show.language, "de",
            "Writer B's language edit must survive concurrent with Writer A's author edit — neither may clobber the other")
    }

    /// Same race, but BOTH writers touch the SAME field to prove ordering
    /// doesn't cause a lost update either — the LAST one to actually commit
    /// (whichever wins the coordinator's serialisation) must win cleanly,
    /// never a silently-reverted intermediate state.
    func testConcurrentUpdatesToSameFieldOneWinsCleanly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        let seedStore = WatchlistStore()
        seedStore.add(makeShow(slug: "race-show-2", title: "Race Show 2"))
        try seedStore.save(to: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let store = try WatchlistStore.load(from: url)
                try store.updateLanguage(slug: "race-show-2", language: "de", to: url)
            }
            group.addTask {
                let store = try WatchlistStore.load(from: url)
                try store.updateLanguage(slug: "race-show-2", language: "en", to: url)
            }
            try await group.waitForAll()
        }

        let final = try WatchlistStore.load(from: url)
        let show = try XCTUnwrap(final.watchlist.shows.first(where: { $0.slug == "race-show-2" }))
        XCTAssertTrue(show.language == "de" || show.language == "en",
            "The final language must be a CLEAN result of one writer or the other — never a torn/corrupted value")
        XCTAssertEqual(final.watchlist.shows.count, 1,
            "The race must never duplicate or drop the show itself — only the contended field is in question")
    }

    /// Verifies the coordinated read-modify-write path never deadlocks —
    /// many concurrent mutations (well beyond a simple pair) must all
    /// complete within a bounded time. A regression here would most likely
    /// manifest as this test timing out (XCTest's default test timeout)
    /// rather than a clean failure.
    func testManyConcurrentMutationsCompleteWithoutDeadlock() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = watchlistURL(in: dir)

        // Distinct `rss` per show — `makeShow`'s default `rss` is a fixed
        // string, and `add(_:)` dedups a new show against an EXISTING one by
        // rss URL as a fallback (avoiding ghost entries when a caller derives
        // a different slug from an identical feed). Ten shows sharing the
        // same rss would collapse into one via that fallback, which would
        // sink this test for a reason having nothing to do with M9.
        let seedStore = WatchlistStore()
        for i in 0..<10 {
            seedStore.add(makeShow(slug: "show-\(i)", title: "Show \(i)", rss: "https://example.com/feed-\(i).xml"))
        }
        try seedStore.save(to: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let store = try WatchlistStore.load(from: url)
                    try store.updateEnabled(slug: "show-\(i)", enabled: false, to: url)
                }
            }
            try await group.waitForAll()
        }

        let final = try WatchlistStore.load(from: url)
        XCTAssertEqual(final.watchlist.shows.count, 10, "No shows must be lost across 10 concurrent mutations")
        for show in final.watchlist.shows {
            XCTAssertFalse(show.enabled, "Every show's independent mutation must have landed: \(show.slug)")
        }
    }
}
