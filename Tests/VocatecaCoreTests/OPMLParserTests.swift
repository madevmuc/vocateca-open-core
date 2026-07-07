import XCTest
@testable import VocatecaCore

final class OPMLParserTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testFlatOutlinesParsed() {
        let opml = data("""
        <?xml version="1.0"?>
        <opml version="2.0"><body>
          <outline type="rss" text="Show A" xmlUrl="https://a.example/rss"/>
          <outline type="rss" title="Show B" xmlUrl="https://b.example/feed"/>
        </body></opml>
        """)
        let feeds = OPMLParser.parse(opml)
        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(feeds[0], OPMLFeed(title: "Show A", feedURL: "https://a.example/rss"))
        XCTAssertEqual(feeds[1].title, "Show B")           // falls back to `title` attr
    }

    func testNestedCategoryOutlinesRecursed() {
        let opml = data("""
        <opml><body>
          <outline text="News">
            <outline type="rss" text="Daily" xmlUrl="https://d.example/rss"/>
          </outline>
        </body></opml>
        """)
        let feeds = OPMLParser.parse(opml)
        XCTAssertEqual(feeds.map(\.feedURL), ["https://d.example/rss"])
    }

    func testOutlinesWithoutXmlUrlSkipped() {
        let opml = data("""
        <opml><body>
          <outline text="Just a folder"/>
          <outline type="rss" text="Real" xmlUrl="https://r.example/rss"/>
        </body></opml>
        """)
        XCTAssertEqual(OPMLParser.parse(opml).map(\.feedURL), ["https://r.example/rss"])
    }

    func testDuplicateFeedURLsDeduped() {
        let opml = data("""
        <opml><body>
          <outline type="rss" text="One" xmlUrl="https://x.example/rss"/>
          <outline type="rss" text="One again" xmlUrl="https://x.example/rss"/>
        </body></opml>
        """)
        XCTAssertEqual(OPMLParser.parse(opml).count, 1)
    }

    func testMalformedXMLReturnsEmptyNotCrash() {
        XCTAssertEqual(OPMLParser.parse(data("<opml><body><outline")), [])
    }

    func testTitleFallsBackToURLWhenNoTextOrTitle() {
        let opml = data(#"<opml><body><outline type="rss" xmlUrl="https://z.example/podcast.xml"/></body></opml>"#)
        let f = OPMLParser.parse(opml)
        XCTAssertEqual(f.count, 1)
        XCTAssertFalse(f[0].title.isEmpty)                 // derived, non-empty
    }
}
