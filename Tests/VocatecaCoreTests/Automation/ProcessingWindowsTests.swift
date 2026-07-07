import XCTest
@testable import VocatecaCore

final class ProcessingWindowsTests: XCTestCase {

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testDisabledIsAlwaysAllowed() {
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(3, 0), enabled: false, windows: ["09:00-17:00"]))
    }

    func testEnabledButNoValidWindowsIsOpen() {
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(3, 0), enabled: true, windows: []))
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(3, 0), enabled: true, windows: ["garbage"]))
    }

    func testDaytimeWindow() {
        let w = ["09:00-17:00"]
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(9, 0), enabled: true, windows: w))
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(16, 59), enabled: true, windows: w))
        XCTAssertFalse(ProcessingWindows.isAllowed(now: at(17, 0), enabled: true, windows: w), "end is exclusive")
        XCTAssertFalse(ProcessingWindows.isAllowed(now: at(8, 59), enabled: true, windows: w))
    }

    func testOvernightWrap() {
        let w = ["22:00-06:00"]
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(23, 30), enabled: true, windows: w))
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(2, 0), enabled: true, windows: w))
        XCTAssertFalse(ProcessingWindows.isAllowed(now: at(12, 0), enabled: true, windows: w))
        XCTAssertFalse(ProcessingWindows.isAllowed(now: at(6, 0), enabled: true, windows: w), "end exclusive")
    }

    func testMultipleWindows() {
        let w = ["00:00-06:00", "22:00-24:00"]
        // 24:00 is malformed (hour 24) → that window is dropped; only 00:00-06:00 valid.
        XCTAssertTrue(ProcessingWindows.isAllowed(now: at(3, 0), enabled: true, windows: w))
        XCTAssertFalse(ProcessingWindows.isAllowed(now: at(23, 0), enabled: true, windows: w))
    }

    func testParsingHelpers() {
        XCTAssertEqual(ProcessingWindows.minutes("09:30"), 570)
        XCTAssertNil(ProcessingWindows.minutes("24:00"))
        XCTAssertNil(ProcessingWindows.minutes("9-30"))
        XCTAssertEqual(ProcessingWindows.parse("22:00-06:00")?.start, 1320)
    }
}
