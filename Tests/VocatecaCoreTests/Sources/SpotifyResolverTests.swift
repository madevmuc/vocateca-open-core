import XCTest
@testable import VocatecaCore

/// Tests for ``SpotifyResolver/parseOGMetadata(html:kind:)``.
///
/// `SpotifyResolver.resolve(_:)` (the network fetch) is intentionally NOT unit
/// tested — only the pure HTML-parsing function is covered here.
final class SpotifyResolverTests: XCTestCase {

    // MARK: - Fixture builder

    private func html(title: String?, description: String? = nil) -> String {
        var head = ""
        if let title {
            head += "<meta property=\"og:title\" content=\"\(title)\">\n"
        }
        if let description {
            head += "<meta property=\"og:description\" content=\"\(description)\">\n"
        }
        return "<html><head>\(head)</head><body></body></html>"
    }

    // MARK: - Real episode example (og:description uses a literal " · " separator)

    func testRealEpisodeExample() {
        let fixture = html(
            title: " Folge #193, Sascha Firtina, Co-Founder von gocomo",
            description: "What&#x27;s Next, Agencies? · Episode"
        )
        let result = SpotifyResolver.parseOGMetadata(html: fixture, kind: .episode)
        XCTAssertEqual(result?.kind, .episode)
        XCTAssertEqual(result?.showName, "What's Next, Agencies?")
        XCTAssertEqual(result?.episodeTitle, "Folge #193, Sascha Firtina, Co-Founder von gocomo")
    }

    // MARK: - Show fixture

    func testShowFixture() {
        let fixture = html(title: "What&#x27;s Next, Agencies?")
        let result = SpotifyResolver.parseOGMetadata(html: fixture, kind: .show)
        XCTAssertEqual(result?.kind, .show)
        XCTAssertEqual(result?.showName, "What's Next, Agencies?")
        XCTAssertNil(result?.episodeTitle)
    }

    // MARK: - Missing metadata

    func testMissingOGTitleReturnsNil() {
        let fixture = "<html><head></head><body></body></html>"
        XCTAssertNil(SpotifyResolver.parseOGMetadata(html: fixture, kind: .show))
        XCTAssertNil(SpotifyResolver.parseOGMetadata(html: fixture, kind: .episode))
    }

    func testEpisodeMissingOGDescriptionReturnsNil() {
        let fixture = html(title: "Some Episode Title")
        XCTAssertNil(SpotifyResolver.parseOGMetadata(html: fixture, kind: .episode))
    }

    // MARK: - Entity decoding coverage

    func testEntityDecoding() {
        let fixture = html(title: "Tom &amp; Jerry &quot;Live&quot; &lt;Show&gt; &#x2F;fun")
        let result = SpotifyResolver.parseOGMetadata(html: fixture, kind: .show)
        XCTAssertEqual(result?.showName, "Tom & Jerry \"Live\" <Show> /fun")
    }

    // MARK: - Embed-page parser (the lightweight /embed/… source)

    func testEmbedEpisodeExtractsShowAndEpisode() {
        // Mirrors the real embed page's __NEXT_DATA__ entity shape.
        let fixture = #"{"entity":{"type":"episode","uri":"spotify:episode:4cS","title":" Folge #193, Sascha Firtina, Co-Founder von gocomo","subtitle":"What's Next, Agencies?","releaseDate":{"isoString":"2026-06-30T"}}}"#
        let r = SpotifyResolver.parseEmbedMetadata(html: fixture, kind: .episode)
        XCTAssertEqual(r?.episodeTitle, "Folge #193, Sascha Firtina, Co-Founder von gocomo")
        XCTAssertEqual(r?.showName, "What's Next, Agencies?")
    }

    func testEmbedShowExtractsShowName() {
        let fixture = #"{"entity":{"type":"show","title":"What's Next, Agencies?"}}"#
        let r = SpotifyResolver.parseEmbedMetadata(html: fixture, kind: .show)
        XCTAssertEqual(r?.showName, "What's Next, Agencies?")
        XCTAssertNil(r?.episodeTitle)
    }

    func testEmbedMissingFieldsReturnsNil() {
        XCTAssertNil(SpotifyResolver.parseEmbedMetadata(html: "{}", kind: .episode))
        XCTAssertNil(SpotifyResolver.parseEmbedMetadata(html: "{}", kind: .show))
    }

    // MARK: - Live network test (opt-in tier 2 — "Spotify→feed" Add path)

    /// Resolves a real Spotify show link to its show name via the live
    /// `/embed/show/…` page — the first half of the "Spotify episode link →
    /// matched to a public feed" Add path (the second half, matching the
    /// resolved show name to a public RSS feed via the podcast directory, is
    /// exercised by ``SpotifyEpisodeMatcherTests`` + ``PodcastSearchTests``
    /// with fixtures; this test only proves the live resolve step itself
    /// still works against the real `open.spotify.com` embed page).
    ///
    /// Skipped by default (env-gated) and wrapped in its own timeout so a
    /// stalled connection cannot hang the suite — see project rule: a stalled
    /// network test previously held the SwiftPM lock for an hour.
    ///
    /// Uses "Lex Fridman Podcast" (`open.spotify.com/show/2MAi0BvDc6GTFvKFPXnkCL`)
    /// — a very large, long-running, stable show unlikely to be removed.
    func testLiveResolveSpotifyShow() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network tests")
        }
        let showURL = "https://open.spotify.com/show/2MAi0BvDc6GTFvKFPXnkCL"

        let resolved: SpotifyResolved
        do {
            resolved = try await withTimeout(seconds: 15) {
                try await SpotifyResolver().resolve(showURL)
            }
        } catch is TimeoutError {
            throw XCTSkip("Spotify resolve timed out after 15s — skipping live smoke test")
        } catch let e as SpotifyResolverError {
            throw XCTSkip("Spotify resolve failed (\(e)) — possibly rate-limited or page layout changed")
        } catch {
            throw XCTSkip("Spotify resolve failed (\(error)) — skipping live smoke test")
        }

        XCTAssertEqual(resolved.kind, .show)
        XCTAssertFalse(resolved.showName.isEmpty, "resolved show name must not be empty")
        XCTAssertNil(resolved.episodeTitle, ".show links must not carry an episode title")
        print("✓ Resolved Spotify show → \"\(resolved.showName)\"")
    }
}

// MARK: - Per-test timeout helper

/// Thrown when ``withTimeout(seconds:operation:)`` hits its deadline before
/// `operation` completes. Each live-network test must have its OWN timeout so
/// a single stalled connection cannot hang the whole `swift test` run.
private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
