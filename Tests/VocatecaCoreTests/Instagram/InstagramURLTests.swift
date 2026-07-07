import XCTest
@testable import VocatecaCore

/// Table-driven tests for ``InstagramURL/parse(_:)``.
///
/// ## Spec interpretation (documented decisions)
///
/// 1. **Handle normalisation**: handles are lowercased; the leading `@` is stripped.
///    Instagram handles are case-insensitive so `NicolasCage` → `nicolascage`.
///
/// 2. **Profile value**: the returned `value` is the bare handle (no `@`, lowercase).
///
/// 3. **Story value**: for story URLs we return the **handle** of the account whose
///    story it is, not the numeric media-id. The media-id is ephemeral and useless
///    for routing/dedup.
///
/// 4. **Reel/Post shortcode**: shortcodes are returned **as-is** (case-sensitive
///    base-62 identifiers; `CxYzABCD` ≠ `cxyzabcd`).
///
/// 5. **Scheme tolerance**: `https://`, `http://`, bare `instagram.com/`, and
///    bare handle all work.
///
/// 6. **Reserved segments**: `/explore`, `/accounts`, `/direct`, `/reels`, `/tv`,
///    `/help`, `/login`, `/signup` are rejected.
///
/// 7. **Junk inputs**: empty string, whitespace-only, contains spaces after stripping,
///    looks like another domain, or starts with `http://` but points to a non-IG host
///    all throw `InstagramURLError.unrecognised`.
final class InstagramURLTests: XCTestCase {

    // MARK: - Test table

    struct Case {
        let input:    String
        let kind:     InstagramURL.Kind?   // nil → expect error
        let value:    String?              // nil → don't care / error
        let label:    String               // for XCTFail messages
    }

    let cases: [Case] = [

        // ── @handle ──────────────────────────────────────────────────────────
        Case(input: "@someuser",        kind: .profile, value: "someuser",   label: "@handle"),
        Case(input: "@SomeUser",        kind: .profile, value: "someuser",   label: "@handle uppercased"),
        Case(input: "@user.name_99",    kind: .profile, value: "user.name_99", label: "@handle with dot and underscore"),
        Case(input: "  @someuser  ",    kind: .profile, value: "someuser",   label: "@handle with surrounding spaces"),
        Case(input: "@",               kind: nil,       value: nil,           label: "bare @ → error"),
        Case(input: "@has space",      kind: nil,       value: nil,           label: "@handle with space → error"),

        // ── Bare handle ──────────────────────────────────────────────────────
        Case(input: "someuser",         kind: .profile, value: "someuser",   label: "bare handle"),
        Case(input: "SomeUser",         kind: .profile, value: "someuser",   label: "bare handle uppercased"),
        Case(input: "user.name",        kind: .profile, value: "user.name",  label: "bare handle with dot"),
        Case(input: "user_99",          kind: .profile, value: "user_99",    label: "bare handle with underscore and digits"),

        // ── Profile URLs ─────────────────────────────────────────────────────
        Case(input: "https://www.instagram.com/someuser",
             kind: .profile, value: "someuser", label: "https://www.instagram.com/<user>"),
        Case(input: "https://www.instagram.com/someuser/",
             kind: .profile, value: "someuser", label: "https://www.instagram.com/<user>/ (trailing slash)"),
        Case(input: "https://instagram.com/someuser",
             kind: .profile, value: "someuser", label: "https://instagram.com/<user>"),
        Case(input: "instagram.com/someuser",
             kind: .profile, value: "someuser", label: "instagram.com/<user> (no scheme)"),
        Case(input: "http://instagram.com/someuser",
             kind: .profile, value: "someuser", label: "http:// profile URL"),

        // ── Reel URLs ────────────────────────────────────────────────────────
        Case(input: "https://www.instagram.com/reel/CxYzABCD/",
             kind: .reel, value: "CxYzABCD", label: "https reel with trailing slash"),
        Case(input: "https://www.instagram.com/reel/CxYzABCD",
             kind: .reel, value: "CxYzABCD", label: "https reel without trailing slash"),
        Case(input: "instagram.com/reel/CxYzABCD/",
             kind: .reel, value: "CxYzABCD", label: "no-scheme reel"),
        Case(input: "https://www.instagram.com/reel/ABC-def_123",
             kind: .reel, value: "ABC-def_123", label: "reel shortcode with dash and underscore"),

        // ── Post URLs ────────────────────────────────────────────────────────
        Case(input: "https://www.instagram.com/p/CxYzABCD/",
             kind: .post, value: "CxYzABCD", label: "https post /p/ with trailing slash"),
        Case(input: "https://www.instagram.com/p/Dw1234EF",
             kind: .post, value: "Dw1234EF",  label: "https post /p/ without trailing slash"),
        Case(input: "instagram.com/p/CxYzABCD",
             kind: .post, value: "CxYzABCD",  label: "no-scheme post /p/"),

        // ── Story URLs ───────────────────────────────────────────────────────
        Case(input: "https://www.instagram.com/stories/someuser/12345678/",
             kind: .story, value: "someuser",  label: "https story with media-id and trailing slash"),
        Case(input: "https://www.instagram.com/stories/SomeUser/12345678",
             kind: .story, value: "someuser",  label: "https story handle uppercased → lowercased"),
        Case(input: "instagram.com/stories/someuser/12345678",
             kind: .story, value: "someuser",  label: "no-scheme story"),
        Case(input: "https://www.instagram.com/stories/someuser/",
             kind: .story, value: "someuser",  label: "story URL with handle but no media-id"),

        // ── Junk / errors ────────────────────────────────────────────────────
        Case(input: "",                 kind: nil, value: nil, label: "empty string → error"),
        Case(input: "   ",             kind: nil, value: nil, label: "whitespace only → error"),
        Case(input: "https://youtube.com/watch?v=abc",
             kind: nil, value: nil, label: "YouTube URL → error"),
        Case(input: "https://www.instagram.com/explore/",
             kind: nil, value: nil, label: "reserved segment /explore → error"),
        Case(input: "https://www.instagram.com/accounts/login/",
             kind: nil, value: nil, label: "reserved segment /accounts → error"),
        Case(input: "https://www.instagram.com/reel/",
             kind: nil, value: nil, label: "reel URL with no shortcode → error"),
        Case(input: "has space",       kind: nil, value: nil, label: "bare string with space → error"),
    ]

    // MARK: - Driver

    func testParseTable() {
        for c in cases {
            do {
                let result = try InstagramURL.parse(c.input)
                if let expectedKind = c.kind {
                    XCTAssertEqual(result.kind, expectedKind,
                                   "[\(c.label)] kind mismatch for input: \(c.input)")
                }
                if let expectedValue = c.value {
                    XCTAssertEqual(result.value, expectedValue,
                                   "[\(c.label)] value mismatch for input: \(c.input)")
                }
                if c.kind == nil {
                    XCTFail("[\(c.label)] expected error but got \(result) for input: \(c.input)")
                }
            } catch InstagramURLError.unrecognised(let msg) {
                if c.kind != nil {
                    XCTFail("[\(c.label)] unexpected error '\(msg)' for input: \(c.input)")
                }
                // else: expected error — pass
            } catch {
                XCTFail("[\(c.label)] unexpected error type \(error) for input: \(c.input)")
            }
        }
    }

    // MARK: - Additional edge-case tests

    func testShortcodePreservesCase() throws {
        // Shortcodes are case-sensitive base-62 identifiers — must NOT be lowercased.
        let r = try InstagramURL.parse("https://www.instagram.com/reel/CxYzABCD/")
        XCTAssertEqual(r.value, "CxYzABCD")
    }

    func testProfileHandleLowercased() throws {
        let r = try InstagramURL.parse("https://www.instagram.com/MyChannel/")
        XCTAssertEqual(r.value, "mychannel")
    }

    func testStoryReturnsHandle() throws {
        // We return the handle (not the numeric story ID).
        let r = try InstagramURL.parse("https://www.instagram.com/stories/NicolasCage/987654321/")
        XCTAssertEqual(r.kind, .story)
        XCTAssertEqual(r.value, "nicolascage")  // lowercased handle
    }

    func testBareHandleWithAtStripped() throws {
        let r = try InstagramURL.parse("@MyPodcast")
        XCTAssertEqual(r.kind, .profile)
        XCTAssertEqual(r.value, "mypodcast")
    }

    func testKindEquality() {
        // Sanity-check the `Equatable` conformance used in assertions above.
        XCTAssertEqual(InstagramURL(kind: .reel, value: "abc"),
                       InstagramURL(kind: .reel, value: "abc"))
        XCTAssertNotEqual(InstagramURL(kind: .reel, value: "abc"),
                          InstagramURL(kind: .post, value: "abc"))
    }
}
