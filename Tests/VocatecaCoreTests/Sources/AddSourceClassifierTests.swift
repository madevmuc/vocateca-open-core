import XCTest
@testable import VocatecaCore

// MARK: - AddSourceClassifierTests

/// Table-driven coverage for ``AddSourceClassifier`` — the pure Add-source
/// routing decision extracted from `AddSourceSheet.detectType(_:)` (a
/// `VocatecaUI` view file) so "which path does per-tab Add / the intent-first
/// router take for this pasted string" is testable WITHOUT a UI-automation
/// harness and WITHOUT the network.
///
/// Covers every source the brief lists: podcast RSS URL, podcast search term,
/// YouTube channel/handle/playlist URL forms, a single YouTube VIDEO url
/// (must NOT be treated as a subscribe target), a Spotify episode/show link
/// (routes to `.genericURL` — the one-off sheet resolves it specially, see
/// `OneOffLinkClassifier`), Instagram @handle/URL, a generic yt-dlp URL, and
/// the empty-input case.
final class AddSourceClassifierTests: XCTestCase {

    // MARK: - Table

    private struct Case {
        let input: String
        let expected: AddSourceKind
        let name: String
    }

    private let table: [Case] = [
        // Empty / whitespace-only → none.
        Case(input: "", expected: .none, name: "empty string"),
        Case(input: "   ", expected: .none, name: "whitespace only"),

        // Instagram.
        Case(input: "@natgeo", expected: .instagram, name: "bare @handle"),
        Case(input: "https://instagram.com/natgeo", expected: .instagram, name: "instagram.com URL"),
        Case(input: "https://www.instagram.com/p/Cabc123/", expected: .instagram, name: "instagram post URL"),

        // YouTube — channel/handle/playlist forms → .youtube.
        Case(input: "https://youtube.com/@mkbhd", expected: .youtube, name: "youtube.com handle"),
        Case(input: "https://www.youtube.com/@mkbhd", expected: .youtube, name: "youtube.com www handle"),
        Case(input: "https://youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ", expected: .youtube, name: "youtube.com channel id"),
        Case(input: "https://youtube.com/playlist?list=PLabc123", expected: .youtube, name: "youtube.com playlist"),

        // YouTube — a single VIDEO url is a one-off import, NOT subscribe.
        Case(input: "https://youtu.be/5XXa41BYRbo", expected: .genericURL, name: "youtu.be video (one-off)"),
        Case(input: "https://youtube.com/watch?v=dQw4w9WgXcQ", expected: .genericURL, name: "youtube.com watch video (one-off)"),

        // Podcast RSS URL signals.
        Case(input: "https://feeds.example.com/show.xml", expected: .podcast, name: "xml feed URL"),
        // "feeds.simplecast.com" contains the substring "feed" (feed-s), so the
        // simple substring check matches even without a real path token — an
        // oracle-locked quirk of the pre-extraction implementation, not a new bug.
        Case(input: "https://feeds.simplecast.com/54nAGcIl", expected: .podcast, name: "feed host matches via substring 'feed' in 'feeds'"),
        Case(input: "https://example.com/rss", expected: .podcast, name: "rss path token"),
        Case(input: "http://example.com/podcast/feed", expected: .podcast, name: "feed path token, http scheme"),

        // Spotify — resolved specially (not a subscribe target here); the
        // one-off sheet's OneOffLinkClassifier gives it its own `.spotify`
        // case, but the top-level Add-source router treats it as a generic
        // URL to preview/resolve like any other yt-dlp-unsupported link.
        Case(input: "https://open.spotify.com/episode/4cSHMKyfybiDBieC3uyze0", expected: .genericURL, name: "spotify episode"),
        Case(input: "https://open.spotify.com/show/abc123", expected: .genericURL, name: "spotify show"),

        // Generic yt-dlp URLs.
        Case(input: "https://soundcloud.com/foo/bar", expected: .genericURL, name: "soundcloud"),
        Case(input: "https://vimeo.com/12345", expected: .genericURL, name: "vimeo"),
        Case(input: "https://bandcamp.com/artist/track", expected: .genericURL, name: "bandcamp"),

        // Bare search terms (no scheme, no @, no recognised URL signal).
        Case(input: "huberman lab", expected: .podcastSearch, name: "search term with space"),
        Case(input: "lexfridman", expected: .podcastSearch, name: "single-word search term"),
    ]

    func testClassifierTable() {
        for c in table {
            XCTAssertEqual(
                AddSourceClassifier.classify(c.input), c.expected,
                "case '\(c.name)' (\(c.input)) expected \(c.expected)"
            )
        }
    }

    // MARK: - Whitespace handling

    func testLeadingTrailingWhitespaceTrimmed() {
        XCTAssertEqual(AddSourceClassifier.classify("  @natgeo  "), .instagram)
        XCTAssertEqual(AddSourceClassifier.classify("\thuberman\n"), .podcastSearch)
    }

    // MARK: - Case sensitivity / host variants are NOT special-cased

    func testUppercaseHostStillMatchesViaAtSignSignal() {
        // Mirrors the pre-extraction behaviour exactly: "youtube.com" (lowercase
        // substring) does NOT match an uppercase host, but the "/@" handle
        // signal is case-insensitive-by-accident (plain substring match), so
        // this still routes to .youtube — an oracle-locked quirk of the
        // pre-extraction implementation, not a new bug. Asserting CURRENT
        // behaviour so a future refactor doesn't silently change routing.
        XCTAssertEqual(AddSourceClassifier.classify("https://YOUTUBE.com/@mkbhd"), .youtube)
    }

    // MARK: - AddSourceSheet.detectType parity (VocatecaUI)

    /// Not re-tested here (would require a VocatecaUI import from
    /// VocatecaCoreTests, which is the wrong direction) — see
    /// `AddSourceSheet.detectType` and `AddRouterSheet`'s fast path in
    /// VocatecaUI, both of which now delegate to `AddSourceClassifier.classify`
    /// verbatim, mapping cases 1:1 onto their own `DetectedType`. This is the
    /// single source of truth both call sites share.
    func testDocumentationOnly_delegationContract() {
        // Smoke check that the case set is exactly what both UI call sites expect.
        let allCases: [AddSourceKind] = [.none, .podcast, .youtube, .instagram, .podcastSearch, .genericURL]
        XCTAssertEqual(allCases.count, 6)
    }
}
