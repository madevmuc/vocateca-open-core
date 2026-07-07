// Tests/VocatecaCoreTests/State/WatchlistAddYouTubeTests.swift
import XCTest
@testable import VocatecaCore

final class WatchlistAddYouTubeTests: XCTestCase {
    func testAddYouTubePersistsYouTubeSourceWithChannelRSS() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = WatchlistStore()
        try store.addYouTube(
            channelID: "UCabcdefghijklmnopqrstuv",
            title: "Veritasium",
            author: "Derek Muller",
            skipShorts: true,
            language: "Auto",
            to: tmp
        )

        let reloaded = try WatchlistStore.load(from: tmp)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first { $0.title == "Veritasium" })
        XCTAssertEqual(show.source, "youtube")
        XCTAssertEqual(show.rss, "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv")
        XCTAssertEqual(show.author, "Derek Muller")
    }

    func testAddYouTubePersistsNonDefaultSkipShortsAndLanguage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = WatchlistStore()
        try store.addYouTube(
            channelID: "UCabcdefghijklmnopqrstuv",
            title: "Kurzgesagt",
            author: "Kurzgesagt Team",
            skipShorts: false,
            language: "en",
            to: tmp
        )

        let reloaded = try WatchlistStore.load(from: tmp)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first { $0.title == "Kurzgesagt" })
        XCTAssertEqual(show.skipShorts, false, "skipShorts false must round-trip through YAML")
        XCTAssertEqual(show.language, "en", "language must round-trip through YAML")
    }

    func testAddYouTubeDefaultsIncludeVideosToTrue() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = WatchlistStore()
        try store.addYouTube(
            channelID: "UCabcdefghijklmnopqrstuv",
            title: "Veritasium",
            author: "Derek Muller",
            skipShorts: true,
            language: "Auto",
            to: tmp
        )

        let reloaded = try WatchlistStore.load(from: tmp)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first { $0.title == "Veritasium" })
        XCTAssertEqual(show.includeVideos, true, "includeVideos must default to true when omitted")
    }

    func testAddYouTubePersistsIncludeVideosFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = WatchlistStore()
        try store.addYouTube(
            channelID: "UCabcdefghijklmnopqrstuv",
            title: "Shorts Only Channel",
            author: "Shorts Creator",
            skipShorts: false,
            includeVideos: false,
            language: "Auto",
            to: tmp
        )

        let reloaded = try WatchlistStore.load(from: tmp)
        let show = try XCTUnwrap(reloaded.watchlist.shows.first { $0.title == "Shorts Only Channel" })
        XCTAssertEqual(show.includeVideos, false, "includeVideos false must round-trip through YAML")
    }
}
