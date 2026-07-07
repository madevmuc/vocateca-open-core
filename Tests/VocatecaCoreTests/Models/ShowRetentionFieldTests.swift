import XCTest
@testable import VocatecaCore

final class ShowRetentionFieldTests: XCTestCase {
    func testDefaultIsFollowGlobal() {
        let show = Show(slug: "s", title: "T", rss: "r")
        XCTAssertEqual(show.mediaRetentionOverrideDays, -1)
    }

    func testDecodesSnakeCaseKey() throws {
        let json = Data(#"{"slug":"s","title":"T","rss":"r","media_retention_override_days":7}"#.utf8)
        let show = try JSONDecoder().decode(Show.self, from: json)
        XCTAssertEqual(show.mediaRetentionOverrideDays, 7)
    }

    func testMissingKeyDefaults() throws {
        let json = Data(#"{"slug":"s","title":"T","rss":"r"}"#.utf8)
        let show = try JSONDecoder().decode(Show.self, from: json)
        XCTAssertEqual(show.mediaRetentionOverrideDays, -1)
    }
}
