import XCTest
import Foundation
@testable import VocatecaCore

/// Watchlist (#5) 5c — `WatchlistScanner` (scan → persist, idempotent).
final class WatchlistScannerTests: XCTestCase {

    private let terms = [
        WatchTerm(id: "t-swift", term: "swift"),
        WatchTerm(id: "t-rust", term: "rust"),
        WatchTerm(id: "t-off", term: "python", enabled: false),
    ]

    func testScanInsertsOneRowPerTermPerEpisode() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = WatchlistScanner(store: store)

        // "swift" appears twice → still one row; "rust" once; "python" disabled → none.
        let text = "swift is great and swift is fast, unlike rust maybe. python ignored."
        let inserted = try scanner.scan(episodeGuid: "g1", showSlug: "s", text: text,
                                        terms: terms, nowISO: "2026-07-01T00:00:00Z")

        XCTAssertEqual(Set(inserted.map(\.termID)), ["t-swift", "t-rust"])
        XCTAssertEqual(try store.fetchWatchlistHits().count, 2)
    }

    func testReScanIsIdempotent() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = WatchlistScanner(store: store)

        let text = "swift swift swift"
        _ = try scanner.scan(episodeGuid: "g1", showSlug: "s", text: text, terms: terms, nowISO: "t")
        let second = try scanner.scan(episodeGuid: "g1", showSlug: "s", text: text, terms: terms, nowISO: "t")

        XCTAssertTrue(second.isEmpty, "re-scan must not insert duplicates")
        XCTAssertEqual(try store.fetchWatchlistHits().count, 1)
    }

    /// Regression for the "Energie" undercount: a term whose only occurrences
    /// in a batch of transcripts are GERMAN COMPOUND words (never the bare
    /// term standalone) must still yield one hit per matching transcript —
    /// proving the scanner (via the fixed `KeywordWatch.evaluate` prefix
    /// match) finds ALL of them, not just a whole-word subset.
    func testScanFindsHitInEveryTranscriptContainingCompoundOnly() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = WatchlistScanner(store: store)
        let energieTerm = [WatchTerm(id: "t-energie", term: "Energie")]

        let compoundOnlyTranscripts: [(guid: String, text: String)] = [
            ("g1", "Die Energiewende kommt schneller als gedacht."),
            ("g2", "Erneuerbare Energien sind die Zukunft."),
            ("g3", "Der Energieausweis ist Pflicht beim Verkauf."),
            ("g4", "Wir brauchen energieeffizientere Gebäude."),
        ]

        var totalInserted = 0
        for (guid, text) in compoundOnlyTranscripts {
            let inserted = try scanner.scan(episodeGuid: guid, showSlug: "s", text: text,
                                            terms: energieTerm, nowISO: "2026-07-16T00:00:00Z")
            totalInserted += inserted.count
        }

        XCTAssertEqual(totalInserted, compoundOnlyTranscripts.count,
                        "every compound-only transcript must produce exactly one hit")
        XCTAssertEqual(try store.fetchWatchlistHits().count, compoundOnlyTranscripts.count)
    }

    func testIdempotencyPreservesReadState() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = WatchlistScanner(store: store)

        _ = try scanner.scan(episodeGuid: "g1", showSlug: "s", text: "swift", terms: terms, nowISO: "t")
        try store.markAllWatchlistHitsRead()
        _ = try scanner.scan(episodeGuid: "g1", showSlug: "s", text: "swift", terms: terms, nowISO: "t")

        // The hit stays read (not resurrected as unread).
        XCTAssertEqual(try store.unreadWatchlistHitCount(), 0)
    }
}
