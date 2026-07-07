import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - LogRelevanceTests
//
// Unit tests for the pure `LogRelevance.relevantLines` heuristic used by the
// Notifications detail panel's focused log excerpt. Fixture log lines only —
// no LogStore, no live network, no timers.

final class LogRelevanceTests: XCTestCase {

    private func line(_ offsetSeconds: TimeInterval, from base: Date,
                       level: LogLevel = .info, component: String = "Test",
                       message: String = "msg", context: [(String, String)] = []) -> LogLine {
        LogLine(date: base.addingTimeInterval(offsetSeconds), level: level,
                component: component, message: message, context: context)
    }

    // MARK: - Time window

    func testLinesWithinWindowAreIncluded() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let lines = [
            line(-90, from: base, message: "too early"),
            line(-30, from: base, message: "just before"),
            line(0,   from: base, message: "exact"),
            line(45,  from: base, message: "just after"),
            line(120, from: base, message: "too late"),
        ]
        let result = LogRelevance.relevantLines(
            in: lines, createdAt: base.timeIntervalSince1970, showSlug: nil, window: 60
        )
        let messages = result.map(\.message)
        XCTAssertEqual(messages, ["just after", "exact", "just before"], "newest-first, window-filtered")
    }

    // MARK: - Slug matching outside the window

    func testLineMentioningSlugOutsideWindowIsIncluded() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let lines = [
            line(-3600, from: base, message: "poll started for huberman-lab"),
            line(-3599, from: base, message: "unrelated show poll"),
            line(0, from: base, message: "notification fired"),
        ]
        let result = LogRelevance.relevantLines(
            in: lines, createdAt: base.timeIntervalSince1970, showSlug: "huberman-lab", window: 60
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.message.contains("huberman-lab") })
        XCTAssertTrue(result.contains { $0.message == "notification fired" })
    }

    func testSlugMatchIsCaseInsensitiveAndChecksContext() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        let lines = [
            line(-9999, from: base, message: "generic failure",
                 context: [("slug", "Finanzfluss")]),
        ]
        let result = LogRelevance.relevantLines(
            in: lines, createdAt: base.timeIntervalSince1970, showSlug: "finanzfluss", window: 60
        )
        XCTAssertEqual(result.count, 1)
    }

    func testNoSlugAndOutsideWindowIsExcluded() {
        let base = Date(timeIntervalSince1970: 4_000_000)
        let lines = [line(-9999, from: base, message: "far away, no slug")]
        let result = LogRelevance.relevantLines(
            in: lines, createdAt: base.timeIntervalSince1970, showSlug: nil, window: 60
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptySlugStringBehavesLikeNilSlug() {
        let base = Date(timeIntervalSince1970: 5_000_000)
        let lines = [line(-9999, from: base, message: "unrelated")]
        let result = LogRelevance.relevantLines(
            in: lines, createdAt: base.timeIntervalSince1970, showSlug: "   ", window: 60
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyInputReturnsEmpty() {
        let result = LogRelevance.relevantLines(in: [], createdAt: 0, showSlug: "anything")
        XCTAssertTrue(result.isEmpty)
    }
}
