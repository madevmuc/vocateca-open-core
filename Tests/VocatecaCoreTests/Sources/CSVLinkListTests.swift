import XCTest
@testable import VocatecaCore

/// Tests for ``CSVLinkList/parse(_:)``.
final class CSVLinkListTests: XCTestCase {

    func testOneURLPerLine() {
        XCTAssertEqual(
            CSVLinkList.parse("https://a.example/1\nhttps://a.example/2"),
            ["https://a.example/1", "https://a.example/2"]
        )
    }

    func testBlankLinesSkipped() {
        XCTAssertEqual(
            CSVLinkList.parse("https://a.example/1\n\n\nhttps://a.example/2").count,
            2
        )
    }

    func testCommentLinesSkipped() {
        XCTAssertEqual(
            CSVLinkList.parse("# a comment\nhttps://a.example/1\n# another"),
            ["https://a.example/1"]
        )
    }

    func testFirstColumnOfCSVRow() {
        XCTAssertEqual(
            CSVLinkList.parse("https://a.example/1,My Title\nhttps://a.example/2,Other"),
            ["https://a.example/1", "https://a.example/2"]
        )
    }

    func testQuotedFirstColumn() {
        XCTAssertEqual(
            CSVLinkList.parse("\"https://a.example/1\",Title"),
            ["https://a.example/1"]
        )
    }

    func testTrailingWhitespaceAndCRLF() {
        XCTAssertEqual(
            CSVLinkList.parse("https://a.example/1 \r\n  https://a.example/2\t\n").count,
            2
        )
    }

    func testEmptyInput() {
        XCTAssertEqual(CSVLinkList.parse(""), [])
    }

    func testMixedLinkKinds() {
        // parser does NOT classify, just extracts
        XCTAssertEqual(
            CSVLinkList.parse("https://youtube.com/watch?v=abc\nhttps://feeds.example.com/show.xml\n@someuser"),
            ["https://youtube.com/watch?v=abc", "https://feeds.example.com/show.xml", "@someuser"]
        )
    }
}
