import XCTest
@testable import VocatecaCore

/// Table-driven tests for ``SpotifyURL/parse(_:)``.
final class SpotifyURLTests: XCTestCase {

    struct Case {
        let input: String
        let kind:  SpotifyURL.Kind?   // nil → expect nil result
        let id:    String?
        let label: String
    }

    let cases: [Case] = [
        // ── Episode URLs ─────────────────────────────────────────────────────
        Case(input: "https://open.spotify.com/episode/4o6VZlOZUeE6PGvQtxIP4H",
             kind: .episode, id: "4o6VZlOZUeE6PGvQtxIP4H", label: "https episode URL"),
        Case(input: "https://open.spotify.com/episode/4o6VZlOZUeE6PGvQtxIP4H/",
             kind: .episode, id: "4o6VZlOZUeE6PGvQtxIP4H", label: "episode URL trailing slash"),
        Case(input: "http://open.spotify.com/episode/4o6VZlOZUeE6PGvQtxIP4H",
             kind: .episode, id: "4o6VZlOZUeE6PGvQtxIP4H", label: "http:// episode URL"),
        Case(input: "https://open.spotify.com/episode/4o6VZlOZUeE6PGvQtxIP4H?si=abc123",
             kind: .episode, id: "4o6VZlOZUeE6PGvQtxIP4H", label: "episode URL with query string"),

        // ── Show URLs ────────────────────────────────────────────────────────
        Case(input: "https://open.spotify.com/show/1a2b3C4d5E6f7G8h9I0jKl",
             kind: .show, id: "1a2b3C4d5E6f7G8h9I0jKl", label: "https show URL"),
        Case(input: "https://open.spotify.com/show/1a2b3C4d5E6f7G8h9I0jKl/",
             kind: .show, id: "1a2b3C4d5E6f7G8h9I0jKl", label: "show URL trailing slash"),
        Case(input: "http://open.spotify.com/show/1a2b3C4d5E6f7G8h9I0jKl",
             kind: .show, id: "1a2b3C4d5E6f7G8h9I0jKl", label: "http:// show URL"),
        Case(input: "https://open.spotify.com/show/1a2b3C4d5E6f7G8h9I0jKl?si=xyz789",
             kind: .show, id: "1a2b3C4d5E6f7G8h9I0jKl", label: "show URL with query string"),

        // ── URI form ─────────────────────────────────────────────────────────
        Case(input: "spotify:episode:4o6VZlOZUeE6PGvQtxIP4H",
             kind: .episode, id: "4o6VZlOZUeE6PGvQtxIP4H", label: "spotify: episode URI"),
        Case(input: "spotify:show:1a2b3C4d5E6f7G8h9I0jKl",
             kind: .show, id: "1a2b3C4d5E6f7G8h9I0jKl", label: "spotify: show URI"),

        // ── Junk / unsupported ───────────────────────────────────────────────
        Case(input: "https://example.com/episode/4o6VZlOZUeE6PGvQtxIP4H",
             kind: nil, id: nil, label: "non-Spotify URL → nil"),
        Case(input: "https://open.spotify.com/track/4o6VZlOZUeE6PGvQtxIP4H",
             kind: nil, id: nil, label: "spotify /track/ path → nil"),
        Case(input: "https://open.spotify.com/playlist/4o6VZlOZUeE6PGvQtxIP4H",
             kind: nil, id: nil, label: "spotify /playlist/ path → nil"),
        Case(input: "https://open.spotify.com/episode/",
             kind: nil, id: nil, label: "malformed: no id → nil"),
        Case(input: "",
             kind: nil, id: nil, label: "empty string → nil"),
        Case(input: "not a url at all",
             kind: nil, id: nil, label: "garbage string → nil"),
    ]

    func testParseTable() {
        for c in cases {
            let result = SpotifyURL.parse(c.input)
            if let expectedKind = c.kind, let expectedID = c.id {
                XCTAssertEqual(result?.kind, expectedKind, "[\(c.label)] kind mismatch for input: \(c.input)")
                XCTAssertEqual(result?.id, expectedID, "[\(c.label)] id mismatch for input: \(c.input)")
            } else {
                XCTAssertNil(result, "[\(c.label)] expected nil for input: \(c.input)")
            }
        }
    }

    func testEquatable() {
        XCTAssertEqual(SpotifyURL(kind: .episode, id: "abc"), SpotifyURL(kind: .episode, id: "abc"))
        XCTAssertNotEqual(SpotifyURL(kind: .episode, id: "abc"), SpotifyURL(kind: .show, id: "abc"))
    }
}
