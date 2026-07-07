import XCTest
@testable import VocatecaCore

// MARK: - WelleD1bTests
//
// Focused tests for the Welle D1b Settings changes:
//   1. instagramStoriesIntervalMinutes default is now 360 (was 60)
//   2. minutesToDate / dateToMinutes round-trip (pure-function replicas)
//   3. Edge cases: clamp at 1440, floor at 30, 24:00 wrap cap at 1410

final class WelleD1bTests: XCTestCase {

    // MARK: - 1. Stories interval default

    func testStoriesIntervalDefault_is360() {
        XCTAssertEqual(Settings.defaultInstagramStoriesIntervalMinutes, 360,
                       "Stories interval default must be 360 min (= 6 h) as of Welle D1b")
    }

    func testNewSettingsStoriesInterval_is360() {
        let s = Settings()
        XCTAssertEqual(s.instagramStoriesIntervalMinutes, 360)
    }

    // MARK: - 2. minutes ↔ Date helpers (pure-function replicas)
    //
    // These replicate the private static helpers in InstagramCard so we can
    // test the conversion logic without a UI dependency.

    private let maxPickerMinutes = 1410  // 23:30

    private func minutesToDate(_ minutes: Int) -> Date {
        let clamped = min(minutes, maxPickerMinutes)
        return Calendar.current.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: Date(timeIntervalSince1970: 0)
        ) ?? Date(timeIntervalSince1970: TimeInterval(clamped * 60))
    }

    private func dateToMinutes(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let total = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return min(max(total, 30), 1440)
    }

    func testRoundTrip_360() {
        let d = minutesToDate(360)
        let back = dateToMinutes(d)
        XCTAssertEqual(back, 360, "360 min should survive the minutes→Date→minutes round-trip")
    }

    func testRoundTrip_30() {
        let d = minutesToDate(30)
        let back = dateToMinutes(d)
        XCTAssertEqual(back, 30)
    }

    func testRoundTrip_90() {
        let d = minutesToDate(90)
        let back = dateToMinutes(d)
        XCTAssertEqual(back, 90)
    }

    // MARK: - 3. Edge cases

    func testClampAbove1440_clampedToMaxPickerThenBackTo1440ViaDatePicker() {
        // 1440 (24:00) is above maxPickerMinutes (1410), so minutesToDate clamps to 23:30.
        // dateToMinutes of 23:30 returns 1410, not 1440.
        // The user reaches 1440 only via the +30 stepper arrow, not the DatePicker field.
        let d = minutesToDate(1440)
        let back = dateToMinutes(d)
        XCTAssertEqual(back, 1410,
                       "1440 min (24:00) is clamped to 1410 (23:30) in the DatePicker field")
    }

    func testFloorAt30_zeroClampedTo30() {
        // dateToMinutes should never return below 30.
        let midnightDate = minutesToDate(0)   // clamped to 0 before conversion
        let back = dateToMinutes(midnightDate)
        // 00:00 extracted → total = 0 → clamped to 30
        XCTAssertEqual(back, 30,
                       "00:00 from DatePicker should be clamped to the minimum 30 min")
    }

    func testDateToMinutes_1410() {
        // 23:30 → 1410, no clamp needed.
        let d = minutesToDate(1410)
        XCTAssertEqual(dateToMinutes(d), 1410)
    }
}
