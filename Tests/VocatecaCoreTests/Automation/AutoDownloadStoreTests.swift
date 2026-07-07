import XCTest
@testable import VocatecaCore

// MARK: - AutoDownloadStoreTests
//
// TDD for AutoDownloadStore (Step 1) and the ingestStatus decision (Step 2).
//
// Uses an isolated UserDefaults suite so tests never touch .standard and
// are fully independent of each other.

final class AutoDownloadStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh AutoDownloadStore backed by a throwaway suite.
    private func makeStore(id: String = UUID().uuidString) -> AutoDownloadStore {
        // Using a unique suite name per test so suites never share state.
        let suite = UserDefaults(suiteName: "com.vocateca.test.autodownload.\(id)")!
        // Clean any pre-existing keys (in case of suite reuse across runs).
        suite.removePersistentDomain(forName: "com.vocateca.test.autodownload.\(id)")
        return AutoDownloadStore(defaults: suite)
    }

    // MARK: - Round-trip: set then read

    func testSetAndReadTrue() {
        let store = makeStore()
        store.setEnabled(true, slug: "lex-fridman")
        XCTAssertTrue(store.isEnabled(slug: "lex-fridman"),
                      "isEnabled must return true after setEnabled(true)")
    }

    func testSetAndReadFalse() {
        let store = makeStore()
        store.setEnabled(true, slug: "my-podcast")
        store.setEnabled(false, slug: "my-podcast")
        XCTAssertFalse(store.isEnabled(slug: "my-podcast"),
                       "isEnabled must return false after setEnabled(false)")
    }

    // MARK: - Default false when key absent

    func testDefaultIsFalseWhenKeyAbsent() {
        let store = makeStore()
        XCTAssertFalse(store.isEnabled(slug: "never-set"),
                       "isEnabled must default to false when key has never been set (safe-by-default)")
    }

    // MARK: - Key format stays compatible

    func testKeyFormat() {
        XCTAssertEqual(AutoDownloadStore.key(for: "lex-fridman"),
                       "autoDownload-lex-fridman",
                       "Key must use the existing format autoDownload-<slug>")
    }

    func testKeyFormatWithComplex() {
        XCTAssertEqual(AutoDownloadStore.key(for: "podcast-with-spaces 123"),
                       "autoDownload-podcast-with-spaces 123")
    }

    // MARK: - enabledSlugs filters correctly

    func testEnabledSlugsEmpty() {
        let store = makeStore()
        let result = store.enabledSlugs(among: ["show-a", "show-b", "show-c"])
        XCTAssertEqual(result, [],
                       "enabledSlugs must return empty when no shows are opted in")
    }

    func testEnabledSlugsFiltersCorrectly() {
        let store = makeStore()
        store.setEnabled(true, slug: "show-a")
        store.setEnabled(false, slug: "show-b")
        store.setEnabled(true, slug: "show-c")

        let result = store.enabledSlugs(among: ["show-a", "show-b", "show-c"])
        XCTAssertEqual(Set(result), Set(["show-a", "show-c"]),
                       "enabledSlugs must return only shows where auto-download is enabled")
    }

    func testEnabledSlugsWithEmptyInput() {
        let store = makeStore()
        store.setEnabled(true, slug: "show-a")
        let result = store.enabledSlugs(among: [])
        XCTAssertEqual(result, [],
                       "enabledSlugs(among: []) must return empty")
    }

    func testEnabledSlugsDoesNotIncludeUnknownSlugs() {
        let store = makeStore()
        store.setEnabled(true, slug: "show-a")
        // "show-b" is not in the 'among' list even though it might be in defaults elsewhere.
        let result = store.enabledSlugs(among: ["show-b"])
        XCTAssertEqual(result, [],
                       "enabledSlugs must only consider slugs in the 'among' list")
    }

    // MARK: - Multiple shows independent

    func testMultipleShowsAreIndependent() {
        let store = makeStore()
        store.setEnabled(true, slug: "show-1")
        store.setEnabled(false, slug: "show-2")
        store.setEnabled(true, slug: "show-3")

        XCTAssertTrue(store.isEnabled(slug: "show-1"))
        XCTAssertFalse(store.isEnabled(slug: "show-2"))
        XCTAssertTrue(store.isEnabled(slug: "show-3"))
    }

    // MARK: - ingestStatus decision (Step 2 pure logic)

    func testIngestStatusWhenAutoDownloadOn() {
        let status = AutoDownloadStore.ingestStatus(autoDownloadOn: true)
        XCTAssertEqual(status, .pending,
                       "ingestStatus(autoDownloadOn: true) must return .pending so the daemon claims it")
    }

    func testIngestStatusWhenAutoDownloadOff() {
        let status = AutoDownloadStore.ingestStatus(autoDownloadOn: false)
        XCTAssertEqual(status, .deferred,
                       "ingestStatus(autoDownloadOn: false) must return .deferred — safe-by-default")
    }

    func testIngestStatusTruthTable() {
        // Exhaustive truth table for the two-input decision.
        XCTAssertEqual(AutoDownloadStore.ingestStatus(autoDownloadOn: true),  .pending)
        XCTAssertEqual(AutoDownloadStore.ingestStatus(autoDownloadOn: false), .deferred)
    }

    // MARK: - Safe-by-default: zero opted-in shows → enabledSlugs returns empty

    func testSafeByDefault_NoShowsOptedIn() {
        let store = makeStore()
        // Simulate all shows with auto-download OFF (either not set, or explicitly false).
        let allSlugs = ["podcast-a", "youtube-channel-b", "podcast-c"]
        let autoSlugs = store.enabledSlugs(among: allSlugs)
        XCTAssertEqual(autoSlugs, [],
                       "Safety: with no shows opted in, enabledSlugs must return [] — daemon processes nothing")
    }
}
