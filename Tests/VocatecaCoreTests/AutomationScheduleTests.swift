// swift/Tests/VocatecaCoreTests/AutomationScheduleTests.swift
import XCTest
@testable import VocatecaCore

final class AutomationScheduleTests: XCTestCase {
    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    func testNextFireLaterToday() {
        // reference 01:00Z, slot 03:00 → 2h
        let d = AutomationSchedule.nextFireDelayLocal(dailyTimeHHMM: "03:00",
                    reference: utc("2026-07-03T01:00:00Z"), calendar: utcCal)
        XCTAssertEqual(d, 2 * 3600, accuracy: 1)
    }

    func testNextFireRollsToTomorrow() {
        // reference 04:00Z, slot 03:00 → 23h
        let d = AutomationSchedule.nextFireDelayLocal(dailyTimeHHMM: "03:00",
                    reference: utc("2026-07-03T04:00:00Z"), calendar: utcCal)
        XCTAssertEqual(d, 23 * 3600, accuracy: 1)
    }

    func testDidMissSlotWhenLastRunWasYesterday() {
        // now 05:00Z today, slot 03:00 already passed today, last run yesterday → missed
        XCTAssertTrue(AutomationSchedule.didMissSlot(
            lastRunISO: "2026-07-02T03:00:00Z", dailyTimeHHMM: "03:00",
            now: utc("2026-07-03T05:00:00Z"), calendar: utcCal))
    }

    func testDidNotMissWhenAlreadyRanToday() {
        XCTAssertFalse(AutomationSchedule.didMissSlot(
            lastRunISO: "2026-07-03T03:05:00Z", dailyTimeHHMM: "03:00",
            now: utc("2026-07-03T05:00:00Z"), calendar: utcCal))
    }

    func testDidNotMissBeforeTodaysSlot() {
        // now 02:00Z, slot 03:00 hasn't arrived yet → not missed
        XCTAssertFalse(AutomationSchedule.didMissSlot(
            lastRunISO: "2026-07-02T03:00:00Z", dailyTimeHHMM: "03:00",
            now: utc("2026-07-03T02:00:00Z"), calendar: utcCal))
    }

    func testSkipReasonPriority() {
        XCTAssertEqual(.notPro, AutomationSchedule.skipReason(isPro: false, dailyCheckEnabled: true, withinWindow: true, onBattery: false, lowPowerMode: false, hasAutoShows: true))
        XCTAssertEqual(.dailyCheckDisabled, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: false, withinWindow: true, onBattery: false, lowPowerMode: false, hasAutoShows: true))
        XCTAssertEqual(.lowPowerMode, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: true, withinWindow: true, onBattery: false, lowPowerMode: true, hasAutoShows: true))
        XCTAssertEqual(.onBattery, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: true, withinWindow: true, onBattery: true, lowPowerMode: false, hasAutoShows: true))
        XCTAssertEqual(.outsideProcessingWindow, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: true, withinWindow: false, onBattery: false, lowPowerMode: false, hasAutoShows: true))
        XCTAssertEqual(.noAutoDownloadShows, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: true, withinWindow: true, onBattery: false, lowPowerMode: false, hasAutoShows: false))
        XCTAssertEqual(.ok, AutomationSchedule.skipReason(isPro: true, dailyCheckEnabled: true, withinWindow: true, onBattery: false, lowPowerMode: false, hasAutoShows: true))
    }

    func testDockPolicy() {
        XCTAssertEqual(.regular,   AutomationSchedule.dockPolicy(runInBackground: true, hideDockIconInBackground: true, windowOpen: true))
        XCTAssertEqual(.accessory, AutomationSchedule.dockPolicy(runInBackground: true, hideDockIconInBackground: true, windowOpen: false))
        XCTAssertEqual(.regular,   AutomationSchedule.dockPolicy(runInBackground: true, hideDockIconInBackground: false, windowOpen: false))
        XCTAssertEqual(.regular,   AutomationSchedule.dockPolicy(runInBackground: false, hideDockIconInBackground: true, windowOpen: false))
    }
}
