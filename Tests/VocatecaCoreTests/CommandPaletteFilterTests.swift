// swift/Tests/VocatecaCoreTests/CommandPaletteFilterTests.swift
import XCTest
@testable import VocatecaCore

final class CommandPaletteFilterTests: XCTestCase {

    private let entries: [CommandPaletteEntry] = [
        CommandPaletteEntry(id: "shows", title: "Shows", subtitle: "Go to Shows", systemImage: "list.bullet"),
        CommandPaletteEntry(id: "queue", title: "Queue", subtitle: "Go to Queue", systemImage: "arrow.triangle.2.circlepath"),
        CommandPaletteEntry(id: "addPodcast", title: "Add Podcast", subtitle: "Follow a new podcast feed", systemImage: "plus"),
        CommandPaletteEntry(id: "refreshAll", title: "Refresh All Shows", subtitle: "Poll every show for new episodes", systemImage: "arrow.clockwise"),
    ]

    func testEmptyQueryReturnsAllInOrder() {
        XCTAssertEqual(CommandPaletteFilter.filter("", entries), entries)
        XCTAssertEqual(CommandPaletteFilter.filter("   ", entries), entries)
    }

    func testQueryMatchesTitleCaseInsensitively() {
        // "queue" only appears in the Queue entry's title+subtitle.
        let result = CommandPaletteFilter.filter("queue", entries)
        XCTAssertEqual(result.map(\.id), ["queue"])

        // "Add Podcast" title match, case-insensitive; no other entry mentions "podcast".
        let upper = CommandPaletteFilter.filter("PODCAST", entries)
        XCTAssertEqual(upper.map(\.id), ["addPodcast"])
    }

    func testQueryMatchesSubtitleCaseInsensitively() {
        let result = CommandPaletteFilter.filter("follow", entries)
        XCTAssertEqual(result.map(\.id), ["addPodcast"])

        let result2 = CommandPaletteFilter.filter("POLL EVERY", entries)
        XCTAssertEqual(result2.map(\.id), ["refreshAll"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertEqual(CommandPaletteFilter.filter("zzzznotfound", entries), [])
    }
}
