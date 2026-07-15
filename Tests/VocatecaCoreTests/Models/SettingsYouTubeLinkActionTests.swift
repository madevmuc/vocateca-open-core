import XCTest
@testable import VocatecaCore

final class SettingsYouTubeLinkActionTests: XCTestCase {
    func testDefaultIsOpenAndExtract() {
        XCTAssertEqual(Settings().youtubeLinkAction, .openAndExtract)
    }

    func testRoundTripsQueueSilently() throws {
        var s = Settings()
        s.youtubeLinkAction = .queueSilently
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.youtubeLinkAction, .queueSilently)
    }

    func testDefaultsWhenKeyAbsent() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.youtubeLinkAction, .openAndExtract)
    }
}
