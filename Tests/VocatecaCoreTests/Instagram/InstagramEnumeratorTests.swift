import XCTest
@testable import VocatecaCore

/// Tests for ``InstagramEnumerator``.
///
/// All tests use ``MockGalleryDLClient`` with canned `[GalleryDLItem]` arrays
/// injected directly — no network, no subprocess, no IG calls.
///
/// Items are ordered **newest-first** (as gallery-dl returns them for Instagram).
final class InstagramEnumeratorTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        shortcode: String,
        timestamp: Date? = nil,
        mediaType: String = "image"
    ) -> GalleryDLItem {
        GalleryDLItem(
            url: "https://cdn.instagram.com/\(shortcode).jpg",
            filename: "\(shortcode).jpg",
            shortcode: shortcode,
            caption: "caption for \(shortcode)",
            timestamp: timestamp,
            mediaType: mediaType
        )
    }

    /// A `GalleryDLClient` backed by a pre-built array (no JSON encoding needed).
    private struct DirectMockClient: GalleryDLClient {
        let items: [GalleryDLItem]
        func enumerate(profile: String) async throws -> [GalleryDLItem] { items }
    }

    // Items (newest→oldest): SC4, SC3, SC2, SC1
    private var fourItems: [GalleryDLItem] {
        [
            makeItem(shortcode: "SC4"),
            makeItem(shortcode: "SC3"),
            makeItem(shortcode: "SC2"),
            makeItem(shortcode: "SC1"),
        ]
    }

    // MARK: - (a) First run, no cursor → all items new, newest becomes cursor

    func testFirstRunNoCursorAllNew() async throws {
        let client = DirectMockClient(items: fourItems)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: [],
            cursor:   nil,
            client:   client
        )

        XCTAssertEqual(result.newItems.count, 4, "All 4 items should be new on first run")
        XCTAssertEqual(result.newCursor, "SC4", "newCursor should be the newest item")
        // On first run with no known shortcodes there's nothing to detect as deleted.
        XCTAssertEqual(result.deletedShortcodes, [])
    }

    // MARK: - (b) Incremental: cursor mid-list → only items above cursor are new

    func testIncrementalCursorMidList() async throws {
        // Previous run saw SC2 as the newest → cursor = "SC2".
        // Now listing: SC4, SC3, SC2, SC1. Fresh window = [SC4, SC3].
        let client = DirectMockClient(items: fourItems)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC2", "SC1"],  // previously known
            cursor:   "SC2",
            client:   client
        )

        let newCodes = result.newItems.compactMap { $0.shortcode }
        XCTAssertEqual(Set(newCodes), ["SC4", "SC3"], "Only SC4 and SC3 should be new")
        XCTAssertEqual(result.newCursor, "SC4")
        // SC4 and SC3 are above cursor but NOT in knownShortcodes — correct, they're new.
        // No known codes exist in the fresh window [SC4, SC3], so no deletions.
        XCTAssertEqual(result.deletedShortcodes, [])
    }

    // MARK: - (c) Nothing new: cursor == newest item → empty newItems

    func testCursorIsNewestNothingNew() async throws {
        // cursor = "SC4" (the newest) → fresh window is empty, nothing new.
        let client = DirectMockClient(items: fourItems)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC4", "SC3", "SC2", "SC1"],
            cursor:   "SC4",
            client:   client
        )

        XCTAssertTrue(result.newItems.isEmpty, "No new items when cursor is newest")
        XCTAssertEqual(result.newCursor, "SC4", "Cursor stays the same")
        XCTAssertTrue(result.deletedShortcodes.isEmpty, "No deletions (fresh window is empty)")
    }

    // MARK: - (d) Deleted detection: full-run (cursor = nil), known shortcode missing from listing

    func testDeletedDetectionFullRun() async throws {
        // Scenario: first run (cursor = nil). We know SC3 existed previously
        // (maybe from a manual import or earlier system). The listing comes back
        // as SC4, SC2, SC1 — SC3 is absent. With a full-profile listing,
        // SC3 can be confidently flagged as deleted.
        //
        // Spec decision: deletion detection is only reliable on a full-profile
        // listing (cursor == nil). In incremental mode (cursor found), we cannot
        // distinguish "below cursor" (not scanned) from "deleted" without re-fetching
        // the full profile — so we suppress deletions in that mode.
        let listingMissingSC3: [GalleryDLItem] = [
            makeItem(shortcode: "SC4"),
            makeItem(shortcode: "SC2"),
            makeItem(shortcode: "SC1"),
        ]
        let client = DirectMockClient(items: listingMissingSC3)

        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC3", "SC2", "SC1"],
            cursor:   nil,  // full run
            client:   client
        )

        // All items (SC4, SC2, SC1) are in the full listing.
        // New items = [SC4] (not in knownShortcodes). SC2 and SC1 are known, not new.
        let newCodes = result.newItems.compactMap { $0.shortcode }
        XCTAssertEqual(newCodes, ["SC4"], "Only SC4 is new; SC2 and SC1 are deduped")
        // SC3 is in knownShortcodes but absent from the full listing → deleted.
        XCTAssertTrue(
            result.deletedShortcodes.contains("SC3"),
            "SC3 should be flagged as deleted (full run); got: \(result.deletedShortcodes)"
        )
        XCTAssertEqual(result.newCursor, "SC4")
    }

    // MARK: - (d2) Incremental mode: deletions are NOT flagged (by design)

    func testIncrementalModeDoesNotFlagDeletions() async throws {
        // In incremental mode (cursor found), we only scan the fresh window above
        // the cursor. We cannot distinguish "code is below cursor" from "code was
        // deleted" without re-fetching the full profile. Deletions are suppressed
        // to prevent false positives.
        let listingMissingSC3: [GalleryDLItem] = [
            makeItem(shortcode: "SC4"),
            makeItem(shortcode: "SC2"),
            makeItem(shortcode: "SC1"),
        ]
        let client = DirectMockClient(items: listingMissingSC3)

        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC3", "SC2", "SC1"],
            cursor:   "SC1",  // incremental — cursor found
            client:   client
        )

        XCTAssertTrue(
            result.deletedShortcodes.isEmpty,
            "Incremental mode must not flag deletions (false positive risk); got: \(result.deletedShortcodes)"
        )
    }

    // MARK: - (e) Dedup against knownShortcodes

    func testDedupAgainstKnownShortcodes() async throws {
        // SC3 and SC2 are already known; SC4 and SC1 are not.
        // cursor = nil (first run), so full listing is fresh window.
        let client = DirectMockClient(items: fourItems)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC3", "SC2"],
            cursor:   nil,
            client:   client
        )

        let newCodes = Set(result.newItems.compactMap { $0.shortcode })
        XCTAssertEqual(newCodes, ["SC4", "SC1"], "SC3 and SC2 should be deduped out")
        XCTAssertEqual(result.newCursor, "SC4")
    }

    // MARK: - (f) Empty profile

    func testEmptyProfile() async throws {
        let client = DirectMockClient(items: [])
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: [],
            cursor:   nil,
            client:   client
        )

        XCTAssertTrue(result.newItems.isEmpty)
        XCTAssertNil(result.newCursor)
        XCTAssertTrue(result.deletedShortcodes.isEmpty)
    }

    // MARK: - (g) Items without shortcodes are skipped for dedup / new tracking

    func testItemsWithoutShortcodesAreSkippedForDedup() async throws {
        // An item without a shortcode can't be deduped or used as a cursor.
        let items: [GalleryDLItem] = [
            makeItem(shortcode: "SC2"),
            GalleryDLItem(url: "https://cdn.example.com/noshortcode.jpg",
                          filename: "noshortcode.jpg",
                          shortcode: nil,
                          caption: nil,
                          timestamp: nil,
                          mediaType: "image"),
            makeItem(shortcode: "SC1"),
        ]
        let client = DirectMockClient(items: items)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: [],
            cursor:   nil,
            client:   client
        )

        // All items with shortcodes should be new; the nil-shortcode item is included
        // in newItems but can't be used as newCursor.
        XCTAssertEqual(result.newCursor, "SC2")  // newest with a shortcode
        let newWithShortcodes = result.newItems.filter { $0.shortcode != nil }
        XCTAssertEqual(Set(newWithShortcodes.compactMap { $0.shortcode }), ["SC2", "SC1"])
    }

    // MARK: - (h) Cursor not in listing (cursor post was deleted)

    func testCursorNotInListingFallsBackToFullWindow() async throws {
        // cursor = "SC_DELETED" which is not in the new listing.
        // The whole listing becomes the fresh window (can't bound it).
        let client = DirectMockClient(items: fourItems)
        let result = try await InstagramEnumerator.enumerate(
            showSlug: "test-show",
            profile:  "testprofile",
            knownShortcodes: ["SC2", "SC1"],
            cursor:   "SC_DELETED",
            client:   client
        )

        // Fresh window = all items (cursor not found)
        let newCodes = Set(result.newItems.compactMap { $0.shortcode })
        XCTAssertEqual(newCodes, ["SC4", "SC3"], "SC4 and SC3 not in knownShortcodes → new")
        XCTAssertEqual(result.newCursor, "SC4")
        // Deleted detection is suppressed when cursor not found (no reliable window bound).
        XCTAssertTrue(result.deletedShortcodes.isEmpty,
                      "Should not flag deletions when cursor post itself is missing")
    }
}
