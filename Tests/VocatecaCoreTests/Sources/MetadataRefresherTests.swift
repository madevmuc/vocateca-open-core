import XCTest
@testable import VocatecaCore

// MARK: - MetadataRefresherTests

/// Unit tests for ``MetadataRefresher``.
///
/// Only the pure Instagram branch is tested here — it requires no network.
/// Podcast/YouTube branches make network calls and are NOT tested.
/// Run with: swift test --filter MetadataRefresherTests
final class MetadataRefresherTests: XCTestCase {

    // MARK: - Instagram — handle derivation (pure, no network)

    func testInstagram_profileURL_derivesHandle() async throws {
        let show = Show(
            slug: "someuser",
            title: "Some User",
            rss: "https://www.instagram.com/someuser",
            source: "instagram"
        )
        let meta = try await MetadataRefresher.fetch(for: show)
        XCTAssertEqual(meta.handle, "someuser",
            "MetadataRefresher should derive @handle from instagram profile URL")
        XCTAssertNil(meta.artworkURL,
            "Instagram branch must not set artworkURL (no network)")
    }

    func testInstagram_atHandleInRSS_derivesHandle() async throws {
        let show = Show(
            slug: "coolcreator",
            title: "Cool Creator",
            rss: "@coolcreator",
            source: "instagram"
        )
        let meta = try await MetadataRefresher.fetch(for: show)
        XCTAssertEqual(meta.handle, "coolcreator")
        XCTAssertNil(meta.artworkURL)
    }

    func testInstagram_bareHandleInRSS_derivesHandle() async throws {
        let show = Show(
            slug: "testuser",
            title: "Test User",
            rss: "testuser",
            source: "instagram"
        )
        let meta = try await MetadataRefresher.fetch(for: show)
        XCTAssertEqual(meta.handle, "testuser")
    }

    func testInstagram_titleDerivedFromHandle() async throws {
        // When handle is derived successfully, title should be the handle (without @)
        let show = Show(
            slug: "someuser",
            title: "Some User",
            rss: "https://www.instagram.com/someuser",
            source: "instagram"
        )
        let meta = try await MetadataRefresher.fetch(for: show)
        XCTAssertEqual(meta.title, "someuser",
            "Instagram refresh should set title = handle (without @)")
    }

    func testInstagram_unrecognisedURL_returnsEmptyHandle() async throws {
        // An unrecognisable Instagram input should not throw — it should return
        // a RefreshedMetadata with nil handle (graceful degradation).
        let show = Show(
            slug: "bad",
            title: "Bad",
            rss: "not-a-valid-instagram-url/reel/p/explore/",
            source: "instagram"
        )
        // Should not throw — just return empty metadata
        let meta = try await MetadataRefresher.fetch(for: show)
        XCTAssertNil(meta.handle)
    }
}
