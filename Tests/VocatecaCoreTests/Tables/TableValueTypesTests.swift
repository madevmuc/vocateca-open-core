import XCTest
@testable import VocatecaCore

/// Tables Task 3 — `SortValue.compare` + `TableLayout` (Codable + `merge`).
final class TableValueTypesTests: XCTestCase {

    // MARK: - SortValue.compare

    func testTextCompareIsCaseInsensitiveAscending() {
        XCTAssertEqual(SortValue.compare(.text("apple"), .text("Banana")), .orderedAscending)
        XCTAssertEqual(SortValue.compare(.text("Banana"), .text("apple")), .orderedDescending)
        XCTAssertEqual(SortValue.compare(.text("ABC"), .text("abc")), .orderedSame)
    }

    func testNumberCompare() {
        XCTAssertEqual(SortValue.compare(.number(1), .number(2)), .orderedAscending)
        XCTAssertEqual(SortValue.compare(.number(2), .number(1)), .orderedDescending)
        XCTAssertEqual(SortValue.compare(.number(3), .number(3)), .orderedSame)
    }

    func testDateCompareLexicalIsChronological() {
        XCTAssertEqual(SortValue.compare(.date("2024-01-01"), .date("2024-02-01")), .orderedAscending)
        XCTAssertEqual(SortValue.compare(.date("2024-02-01"), .date("2024-01-01")), .orderedDescending)
        XCTAssertEqual(SortValue.compare(.date("2024-01-01"), .date("2024-01-01")), .orderedSame)
    }

    func testMismatchedCasesAreOrderedSame() {
        XCTAssertEqual(SortValue.compare(.text("x"), .number(1)), .orderedSame)
    }

    // MARK: - TableLayout Codable

    func testTableLayoutCodableRoundTrip() throws {
        let layout = TableLayout(
            columns: [
                ColumnState(id: "title", visible: true, width: 220, order: 0),
                ColumnState(id: "added", visible: false, width: 100, order: 1),
            ],
            sort: SortState(columnID: "title", ascending: true)
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TableLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }

    // MARK: - merge(withAvailable:)

    func testMergeKeepsExistingDropsUnknownAppendsNew() {
        // Persisted: "title" (customised) + "legacy" (no longer available).
        let persisted = TableLayout(
            columns: [
                ColumnState(id: "title", visible: false, width: 300, order: 0),
                ColumnState(id: "legacy", visible: true, width: 80, order: 1),
            ],
            sort: SortState(columnID: "legacy", ascending: true)  // points at a stale column
        )
        // Available now: "title" + a new "added".
        let available = [
            ColumnState(id: "title", visible: true, width: 220, order: 0),
            ColumnState(id: "added", visible: true, width: 100, order: 5),
        ]

        let merged = persisted.merge(withAvailable: available)

        // "legacy" dropped; "title" kept with USER prefs (visible:false, width:300).
        let ids = merged.columns.map(\.id)
        XCTAssertEqual(ids, ["title", "added"])
        let title = merged.columns.first { $0.id == "title" }
        XCTAssertEqual(title?.visible, false)
        XCTAssertEqual(title?.width, 300)
        // "added" appended after existing order.
        let added = merged.columns.first { $0.id == "added" }
        XCTAssertEqual(added?.order, 1)
        // Sort cleared because "legacy" vanished.
        XCTAssertNil(merged.sort)
    }

    func testMergeDedupesRepeatedColumnIDs() {
        // A corrupted layout with a duplicated "title" id must collapse to one.
        let persisted = TableLayout(
            columns: [
                ColumnState(id: "title", visible: true, width: 200, order: 0),
                ColumnState(id: "title", visible: false, width: 999, order: 1),
            ],
            sort: nil
        )
        let available = [ColumnState(id: "title", visible: true, width: 200, order: 0)]
        let merged = persisted.merge(withAvailable: available)
        XCTAssertEqual(merged.columns.filter { $0.id == "title" }.count, 1)
        // Keeps the FIRST occurrence's user prefs (visible:true, width:200).
        XCTAssertEqual(merged.columns.first?.width, 200)
    }

    func testMergePreservesValidSort() {
        let persisted = TableLayout(
            columns: [ColumnState(id: "title", visible: true, width: 200, order: 0)],
            sort: SortState(columnID: "title", ascending: false)
        )
        let available = [ColumnState(id: "title", visible: true, width: 200, order: 0)]
        let merged = persisted.merge(withAvailable: available)
        XCTAssertEqual(merged.sort, SortState(columnID: "title", ascending: false))
    }
}
