import XCTest
@testable import VocatecaCore

// MARK: - ShowDisplayNameTests

/// Tests for ``Show/displayName`` and ``Show/displayAuthor`` precedence.
///
/// `displayName` precedence: `customTitle` → `title` → `displayHandle` →
/// `author` → `slug` (the slug must never win when any real name exists).
///
/// `displayAuthor` precedence: `creator` → `displayHandle` → `author`
/// (returns `nil` when none are available).
final class ShowDisplayNameTests: XCTestCase {

    // MARK: - Helpers

    private func show(
        slug: String = "test-slug",
        title: String = "Test Show",
        source: String = "podcast",
        rss: String = "",
        author: String? = nil,
        creator: String? = nil,
        customTitle: String? = nil
    ) -> Show {
        Show(slug: slug, title: title, rss: rss, source: source,
             author: author, creator: creator, customTitle: customTitle)
    }

    // MARK: - displayName precedence

    func testDisplayName_customTitleWinsOverEverything() {
        let s = show(title: "Feed Title", author: "Feed Author", creator: "Some Creator",
                     customTitle: "My Custom Name")
        XCTAssertEqual(s.displayName, "My Custom Name")
    }

    func testDisplayName_whitespaceOnlyCustomTitleIsIgnored() {
        // A whitespace-only customTitle must NOT win — falls through to title.
        let s = show(title: "Feed Title", customTitle: "   ")
        XCTAssertEqual(s.displayName, "Feed Title")
    }

    func testDisplayName_fallsBackToTitleWhenNoCustomTitle() {
        let s = show(title: "Feed Title")
        XCTAssertEqual(s.displayName, "Feed Title")
    }

    func testDisplayName_fallsBackToDisplayHandleWhenTitleEmpty() {
        // Empty title + a YouTube /@handle URL → displayHandle wins.
        let s = show(title: "", source: "youtube", rss: "https://www.youtube.com/@somechannel")
        XCTAssertEqual(s.displayName, "@somechannel")
    }

    func testDisplayName_fallsBackToAuthorWhenTitleAndHandleEmpty() {
        // Empty title, podcast source (no displayHandle) → author wins.
        let s = show(title: "", source: "podcast", author: "Some Author")
        XCTAssertEqual(s.displayName, "Some Author")
    }

    func testDisplayName_slugIsLastDitchFallback() {
        // Nothing else available → slug, and ONLY then.
        let s = show(slug: "my-slug", title: "", source: "podcast", author: nil)
        XCTAssertEqual(s.displayName, "my-slug")
    }

    func testDisplayName_slugNeverWinsWhenTitleExists() {
        // Regression guard for the Queue slug-leak bug: any real title beats the slug.
        let s = show(slug: "some-kebab-case-slug", title: "The Real Title")
        XCTAssertEqual(s.displayName, "The Real Title")
        XCTAssertNotEqual(s.displayName, s.slug)
    }

    // MARK: - displayAuthor precedence

    func testDisplayAuthor_creatorWinsOverEverything() {
        let s = show(source: "youtube", rss: "https://www.youtube.com/@somechannel",
                     author: "Feed Author", creator: "Explicit Creator")
        XCTAssertEqual(s.displayAuthor, "Explicit Creator")
    }

    func testDisplayAuthor_fallsBackToDisplayHandleWhenNoCreator() {
        let s = show(source: "youtube", rss: "https://www.youtube.com/@somechannel", author: "Feed Author")
        XCTAssertEqual(s.displayAuthor, "@somechannel")
    }

    func testDisplayAuthor_fallsBackToAuthorWhenNoCreatorOrHandle() {
        let s = show(source: "podcast", author: "Feed Author")
        XCTAssertEqual(s.displayAuthor, "Feed Author")
    }

    func testDisplayAuthor_nilWhenNoneAvailable() {
        let s = show(source: "podcast", author: nil, creator: nil)
        XCTAssertNil(s.displayAuthor)
    }

    func testDisplayAuthor_neverFallsBackToSlug() {
        // displayAuthor is a subline, not an identity — must stay nil, never the slug.
        let s = show(slug: "some-slug", source: "podcast", author: nil, creator: nil)
        XCTAssertNil(s.displayAuthor)
    }

    // MARK: - Rename-override end-to-end (customTitle clears back to title)

    func testDisplayName_clearingCustomTitleRevertsToFeedTitle() {
        var s = show(title: "Feed Title", customTitle: "Renamed")
        XCTAssertEqual(s.displayName, "Renamed")
        s.customTitle = nil
        XCTAssertEqual(s.displayName, "Feed Title")
    }
}
