import XCTest
@testable import VocatecaCore

/// Oracle-parity tests for ``shouldCatchUp(lastCheckISO:dailyTimeHHMM:now:)``.
///
/// Loads the golden fixture produced by `swift/oracle/generate_fixtures.py`
/// (which calls the real Python `core.scheduler.should_catch_up`) and asserts
/// that the Swift port produces byte/bool-exact matches for every case.
///
/// The fixture covers all logical branches:
/// - `lastCheckISO == nil` → always true
/// - `now < todaySlot` → false (slot not reached)
/// - `now >= todaySlot && lastCheck < todaySlot` → true (missed the slot)
/// - `now >= todaySlot && lastCheck >= todaySlot` → false (already ran today)
final class CatchUpOracleTests: XCTestCase {

    // MARK: - Fixture model

    private struct OracleCase: Decodable {
        let lastCheckIso: String?
        let dailyTimeHhmm: String
        let nowIso: String
        let output: Bool

        enum CodingKeys: String, CodingKey {
            case lastCheckIso    = "last_check_iso"
            case dailyTimeHhmm   = "daily_time_hhmm"
            case nowIso          = "now_iso"
            case output
        }
    }

    // MARK: - Fixture loading

    private func loadFixture() throws -> [OracleCase] {
        guard let url = Bundle.module.url(
            forResource: "should_catch_up",
            withExtension: "json",
            subdirectory: "Fixtures/oracle"
        ) else {
            XCTFail("Fixture not found in bundle: Fixtures/oracle/should_catch_up.json")
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([OracleCase].self, from: data)
    }

    // MARK: - ISO-8601 parsing (matches the CatchUp.swift internal parser)

    private func parseISO8601(_ s: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")!
        for f in formats {
            fmt.dateFormat = f
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Oracle parity test

    func testShouldCatchUpOracleParity() throws {
        let cases = try loadFixture()
        XCTAssertFalse(cases.isEmpty, "should_catch_up fixture must not be empty")

        var failures = 0
        for (i, c) in cases.enumerated() {
            guard let now = parseISO8601(c.nowIso) else {
                XCTFail("Case \(i): cannot parse now_iso: \(c.nowIso)")
                continue
            }
            let got = shouldCatchUp(
                lastCheckISO: c.lastCheckIso,
                dailyTimeHHMM: c.dailyTimeHhmm,
                now: now
            )
            if got != c.output {
                XCTFail("""
                    shouldCatchUp oracle mismatch at case \(i):
                      lastCheckISO:    \(c.lastCheckIso ?? "nil")
                      dailyTimeHHMM:   \(c.dailyTimeHhmm)
                      now:             \(c.nowIso)
                      expected:        \(c.output)
                      got:             \(got)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("shouldCatchUp: all \(cases.count) oracle cases passed ✓")
        }
    }

    // MARK: - Spot checks (not relying on fixture, exercise directly)

    func testNilLastCheckAlwaysCatchesUp() {
        // Regardless of daily time or now, nil last check → always catch up.
        let now = Date()
        XCTAssertTrue(shouldCatchUp(lastCheckISO: nil, dailyTimeHHMM: "09:00", now: now))
        XCTAssertTrue(shouldCatchUp(lastCheckISO: nil, dailyTimeHHMM: "00:00", now: now))
        XCTAssertTrue(shouldCatchUp(lastCheckISO: nil, dailyTimeHHMM: "23:59", now: now))
    }

    func testNoMissIfLastRunAfterSlotToday() {
        // last ran at 09:30 today, slot is 09:00, now is 10:00 → no catch up.
        let now = parseISO8601("2026-06-28T10:00:00+00:00")!
        let result = shouldCatchUp(
            lastCheckISO: "2026-06-28T09:30:00+00:00",
            dailyTimeHHMM: "09:00",
            now: now
        )
        XCTAssertFalse(result, "Should not catch up when last run was after today's slot")
    }

    func testMissWhenSlotPassedAndLastRunWasYesterday() {
        // Last ran yesterday at 10am, slot is 09:00, now is 10am today → catch up.
        let now = parseISO8601("2026-06-28T10:00:00+00:00")!
        let result = shouldCatchUp(
            lastCheckISO: "2026-06-27T10:00:00+00:00",
            dailyTimeHHMM: "09:00",
            now: now
        )
        XCTAssertTrue(result, "Should catch up when slot passed and last run was yesterday")
    }

    func testNoMissBeforeSlotToday() {
        // Slot is 09:00, now is 08:30 → slot not yet reached, no catch up.
        let now = parseISO8601("2026-06-28T08:30:00+00:00")!
        let result = shouldCatchUp(
            lastCheckISO: "2026-06-27T10:00:00+00:00",
            dailyTimeHHMM: "09:00",
            now: now
        )
        XCTAssertFalse(result, "Should not catch up before today's slot has passed")
    }
}
