import XCTest
@testable import VocatecaCore

/// Tests for the `.html` transcript export renderer.
final class TranscriptFormatHTMLTests: XCTestCase {

    func testHTMLEscapesSpecialCharacters() {
        XCTAssertEqual(TranscriptFormat.htmlEscape("Tom & <b>\"Jerry\"</b> 'x'"),
                       "Tom &amp; &lt;b&gt;&quot;Jerry&quot;&lt;/b&gt; &#39;x&#39;")
    }

    func testRenderEpisodeHTMLWrapsBodyAndEscapesTitle() {
        let html = TranscriptFormat.renderEpisodeHTML(
            title: "A & B",
            showSlug: "my-show",
            pubDate: "2026-07-02T00:00:00",
            body: "First line\nSecond <script> line"
        )
        XCTAssertTrue(html.contains("<title>A &amp; B</title>"))
        XCTAssertTrue(html.contains("<h1>A &amp; B</h1>"))
        XCTAssertTrue(html.contains("<p>First line</p>"))
        XCTAssertTrue(html.contains("<p>Second &lt;script&gt; line</p>"))
        XCTAssertTrue(html.contains("my-show · 2026-07-02T00:00:00"))
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
    }

    func testRenderEpisodeHTMLEmptyBodyStillValid() {
        let html = TranscriptFormat.renderEpisodeHTML(
            title: "T", showSlug: "s", pubDate: "", body: "")
        XCTAssertTrue(html.contains("<h1>T</h1>"))
        XCTAssertTrue(html.contains("</html>"))
    }
}
