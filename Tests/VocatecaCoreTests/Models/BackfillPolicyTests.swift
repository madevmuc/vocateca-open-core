import XCTest
@testable import VocatecaCore

/// Unit tests for `BackfillPolicy.inScopeGuids` — pure logic, no I/O.
final class BackfillPolicyTests: XCTestCase {

    private func ep(_ guid: String, _ pubDate: String) -> (guid: String, pubDate: String) {
        (guid: guid, pubDate: pubDate)
    }

    // MARK: - .all

    func testAllModeReturnsEveryGuid() {
        let policy = BackfillPolicy(mode: .all, n: 10, sinceDate: "", subscribedAt: "2026-01-01")
        let episodes = [ep("a", "2026-01-01"), ep("b", ""), ep("c", "2026-06-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["a", "b", "c"]))
    }

    func testAllModeEmptyInput() {
        let policy = BackfillPolicy(mode: .all, n: 10, sinceDate: "", subscribedAt: "2026-01-01")
        XCTAssertTrue(policy.inScopeGuids(episodes: []).isEmpty)
    }

    // MARK: - .lastN

    func testLastNPicksNewestByPubDateDesc() {
        let policy = BackfillPolicy(mode: .lastN, n: 2, sinceDate: "", subscribedAt: "2026-01-01")
        let episodes = [
            ep("old", "2026-01-01"),
            ep("mid", "2026-03-01"),
            ep("new", "2026-06-01"),
        ]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["mid", "new"]))
    }

    func testLastNUnsortedInputStillPicksNewest() {
        let policy = BackfillPolicy(mode: .lastN, n: 1, sinceDate: "", subscribedAt: "2026-01-01")
        // Deliberately out of order.
        let episodes = [ep("mid", "2026-03-01"), ep("new", "2026-06-01"), ep("old", "2026-01-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["new"]))
    }

    func testLastNGreaterThanCountReturnsAll() {
        let policy = BackfillPolicy(mode: .lastN, n: 100, sinceDate: "", subscribedAt: "2026-01-01")
        let episodes = [ep("a", "2026-01-01"), ep("b", "2026-02-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["a", "b"]))
    }

    func testLastNZeroOrNegativeReturnsEmpty() {
        let episodes = [ep("a", "2026-01-01")]
        XCTAssertTrue(BackfillPolicy(mode: .lastN, n: 0, sinceDate: "", subscribedAt: "2026-01-01")
            .inScopeGuids(episodes: episodes).isEmpty)
        XCTAssertTrue(BackfillPolicy(mode: .lastN, n: -5, sinceDate: "", subscribedAt: "2026-01-01")
            .inScopeGuids(episodes: episodes).isEmpty)
    }

    func testLastNEmptyPubDatesSortLastNeverChosen() {
        let policy = BackfillPolicy(mode: .lastN, n: 1, sinceDate: "", subscribedAt: "2026-01-01")
        let episodes = [ep("noDate", ""), ep("hasDate", "2020-01-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["hasDate"]))
    }

    func testLastNEmptyInput() {
        let policy = BackfillPolicy(mode: .lastN, n: 5, sinceDate: "", subscribedAt: "2026-01-01")
        XCTAssertTrue(policy.inScopeGuids(episodes: []).isEmpty)
    }

    // MARK: - .sinceDate

    func testSinceDateIncludesOnAndAfterBoundary() {
        let policy = BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "2026-03-01", subscribedAt: "2026-01-01")
        let episodes = [
            ep("before", "2026-02-28"),
            ep("onBoundary", "2026-03-01"),
            ep("after", "2026-03-02"),
        ]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["onBoundary", "after"]))
    }

    func testSinceDateExcludesMalformedOrEmptyPubDates() {
        let policy = BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "2026-03-01", subscribedAt: "2026-01-01")
        let episodes = [ep("empty", ""), ep("bad", "not-a-date"), ep("good", "2026-04-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["good"]))
    }

    func testSinceDateEmptyOrMalformedSinceReturnsEmpty() {
        let episodes = [ep("a", "2026-04-01")]
        XCTAssertTrue(BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "", subscribedAt: "2026-01-01")
            .inScopeGuids(episodes: episodes).isEmpty)
        XCTAssertTrue(BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "bogus", subscribedAt: "2026-01-01")
            .inScopeGuids(episodes: episodes).isEmpty)
    }

    func testSinceDateEmptyInput() {
        let policy = BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "2026-01-01", subscribedAt: "2026-01-01")
        XCTAssertTrue(policy.inScopeGuids(episodes: []).isEmpty)
    }

    // MARK: - .onlyNew

    func testOnlyNewExcludesSubscriptionDateItself() {
        let policy = BackfillPolicy(mode: .onlyNew, n: 10, sinceDate: "", subscribedAt: "2026-06-01")
        let episodes = [
            ep("onSubscribeDay", "2026-06-01"),
            ep("before", "2026-05-01"),
            ep("after", "2026-06-02"),
        ]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["after"]),
            "onlyNew is strictly AFTER subscribedAt — the subscribe-day episode itself is out of scope")
    }

    func testOnlyNewExcludesMalformedOrEmptyPubDates() {
        let policy = BackfillPolicy(mode: .onlyNew, n: 10, sinceDate: "", subscribedAt: "2026-01-01")
        let episodes = [ep("empty", ""), ep("bad", "??"), ep("good", "2026-02-01")]
        XCTAssertEqual(policy.inScopeGuids(episodes: episodes), Set(["good"]))
    }

    func testOnlyNewMalformedSubscribedAtReturnsEmpty() {
        let episodes = [ep("a", "2026-04-01")]
        XCTAssertTrue(BackfillPolicy(mode: .onlyNew, n: 10, sinceDate: "", subscribedAt: "")
            .inScopeGuids(episodes: episodes).isEmpty)
    }

    func testOnlyNewEmptyInput() {
        let policy = BackfillPolicy(mode: .onlyNew, n: 10, sinceDate: "", subscribedAt: "2026-01-01")
        XCTAssertTrue(policy.inScopeGuids(episodes: []).isEmpty)
    }

    // MARK: - BackfillMode

    func testDisplayNamesAreNonEmpty() {
        for mode in BackfillMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testRawValuesMatchYAMLKeys() {
        XCTAssertEqual(BackfillMode.all.rawValue, "all")
        XCTAssertEqual(BackfillMode.lastN.rawValue, "last_n")
        XCTAssertEqual(BackfillMode.sinceDate.rawValue, "since_date")
        XCTAssertEqual(BackfillMode.onlyNew.rawValue, "only_new")
    }

    // MARK: - init(show:)

    func testInitFromShowReadsStoredFields() {
        var show = Show(slug: "s", title: "T", rss: "r")
        show.backfillMode = "last_n"
        show.backfillN = 5
        show.backfillSince = "2026-01-01"
        show.addedAt = "2026-02-02"

        let policy = BackfillPolicy(show: show)
        XCTAssertEqual(policy.mode, .lastN)
        XCTAssertEqual(policy.n, 5)
        XCTAssertEqual(policy.sinceDate, "2026-01-01")
        XCTAssertEqual(policy.subscribedAt, "2026-02-02")
    }

    func testInitFromShowUnknownModeFallsBackToAll() {
        var show = Show(slug: "s", title: "T", rss: "r")
        show.backfillMode = "some-future-mode"
        XCTAssertEqual(BackfillPolicy(show: show).mode, .all)
    }
}
