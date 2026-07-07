import XCTest
@testable import VocatecaCore

// MARK: - NextStepBarDismissalStoreTests
//
// Uses an isolated UserDefaults suite per test so tests never touch .standard
// and are fully independent of each other (mirrors AutoDownloadStoreTests).

final class NextStepBarDismissalStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(id: String = UUID().uuidString) -> NextStepBarDismissalStore {
        let suiteName = "com.vocateca.test.nextstepbar.\(id)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return NextStepBarDismissalStore(defaults: suite)
    }

    // MARK: - Default nil when never dismissed

    func testDefaultIsNilWhenNeverDismissed() {
        let store = makeStore()
        XCTAssertNil(store.dismissedFingerprint(),
                     "A fresh install must report no dismissed fingerprint")
    }

    // MARK: - Round-trip: dismiss then read

    func testDismissThenRead() {
        let store = makeStore()
        store.dismiss(fingerprint: "7|2026-07-04T10:00:00Z")
        XCTAssertEqual(store.dismissedFingerprint(), "7|2026-07-04T10:00:00Z")
    }

    // MARK: - A second dismiss overwrites the first

    func testSecondDismissOverwritesFirst() {
        let store = makeStore()
        store.dismiss(fingerprint: "4|2026-07-04")
        store.dismiss(fingerprint: "9|2026-07-05")
        XCTAssertEqual(store.dismissedFingerprint(), "9|2026-07-05",
                       "Only the most recently dismissed batch's fingerprint is retained")
    }

    // MARK: - Key format

    func testKeyFormat() {
        XCTAssertEqual(NextStepBarDismissalStore.key, "nextStepBar.dismissedFingerprint")
    }

    // MARK: - Independent suites never leak into each other

    func testIndependentStoresDoNotShareState() {
        let storeA = makeStore(id: "a")
        let storeB = makeStore(id: "b")
        storeA.dismiss(fingerprint: "1|x")
        XCTAssertNil(storeB.dismissedFingerprint(),
                     "Separate UserDefaults suites must not leak dismissal state")
    }
}
