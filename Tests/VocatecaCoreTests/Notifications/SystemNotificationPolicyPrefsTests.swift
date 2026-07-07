import XCTest
import Foundation
@testable import VocatecaCore

/// Audit #2 — quiet-hours / on-success / media-type enforcement in
/// `SystemNotificationPolicy.shouldForwardToSystem` + `isWithinQuietHours`.
final class SystemNotificationPolicyPrefsTests: XCTestCase {

    /// A `Date` at the given local wall-clock time today.
    private func localTime(_ hour: Int, _ minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    private let allMedia = ["podcast", "youtube", "instagram"]

    // MARK: - Quiet hours

    func testQuietHoursWrapMidnightInside() {
        // Window 22:00–08:00 (wraps). 23:30 and 07:00 are inside; 12:00 is outside.
        XCTAssertTrue(SystemNotificationPolicy.isWithinQuietHours(now: localTime(23, 30), start: "22:00", end: "08:00"))
        XCTAssertTrue(SystemNotificationPolicy.isWithinQuietHours(now: localTime(7, 0), start: "22:00", end: "08:00"))
        XCTAssertFalse(SystemNotificationPolicy.isWithinQuietHours(now: localTime(12, 0), start: "22:00", end: "08:00"))
    }

    func testQuietHoursSameDayWindow() {
        // Window 09:00–17:00 (no wrap). 12:00 inside; 08:59 and 17:00 outside (end exclusive).
        XCTAssertTrue(SystemNotificationPolicy.isWithinQuietHours(now: localTime(12, 0), start: "09:00", end: "17:00"))
        XCTAssertFalse(SystemNotificationPolicy.isWithinQuietHours(now: localTime(8, 59), start: "09:00", end: "17:00"))
        XCTAssertFalse(SystemNotificationPolicy.isWithinQuietHours(now: localTime(17, 0), start: "09:00", end: "17:00"))
    }

    func testQuietHoursZeroLengthAndUnparseable() {
        XCTAssertFalse(SystemNotificationPolicy.isWithinQuietHours(now: localTime(3, 0), start: "08:00", end: "08:00"))
        XCTAssertFalse(SystemNotificationPolicy.isWithinQuietHours(now: localTime(3, 0), start: "nonsense", end: "08:00"))
    }

    // MARK: - Composed shouldForwardToSystem

    /// Helper with sensible defaults; override per test.
    private func forward(
        kind: NotifKindKey = .failure,
        isPro: Bool = false,
        perKind: [String: Bool] = ["failure": true],
        onSuccess: Bool = true,
        mediaTypes: [String]? = nil,
        mediaType: String? = nil,
        quietEnabled: Bool = false,
        now: Date? = nil
    ) -> Bool {
        SystemNotificationPolicy.shouldForwardToSystem(
            kind: kind, isPro: isPro, perKind: perKind,
            notifyOnSuccess: onSuccess,
            notifyMediaTypes: mediaTypes ?? allMedia,
            mediaType: mediaType,
            quietHoursEnabled: quietEnabled, quietStart: "22:00", quietEnd: "08:00",
            now: now ?? localTime(12, 0)
        )
    }

    func testLayer1SuppressionStillApplies() {
        // No per-kind override + non-Pro default false ⇒ suppressed regardless of other layers.
        XCTAssertFalse(forward(kind: .newEpisode, perKind: [:]))
    }

    func testOnSuccessGateSuppressesSuccessKinds() {
        XCTAssertFalse(forward(kind: .newEpisode, perKind: ["newEpisode": true], onSuccess: false))
        XCTAssertFalse(forward(kind: .runFinished, perKind: ["runFinished": true], onSuccess: false))
        // Failure is not a success kind — unaffected.
        XCTAssertTrue(forward(kind: .failure, perKind: ["failure": true], onSuccess: false))
    }

    func testMediaTypeFilter() {
        // youtube not in the allowed set ⇒ suppressed.
        XCTAssertFalse(forward(kind: .newEpisode, perKind: ["newEpisode": true],
                               mediaTypes: ["podcast"], mediaType: "youtube"))
        // In the set ⇒ allowed.
        XCTAssertTrue(forward(kind: .newEpisode, perKind: ["newEpisode": true],
                              mediaTypes: ["podcast", "youtube"], mediaType: "youtube"))
        // nil mediaType ⇒ fail-open (not filtered).
        XCTAssertTrue(forward(kind: .newEpisode, perKind: ["newEpisode": true],
                              mediaTypes: ["podcast"], mediaType: nil))
    }

    func testQuietHoursSuppressEvenWithExplicitPerKindOn() {
        // Explicit per-kind ON, but inside quiet hours ⇒ suppressed (time-based DND wins).
        XCTAssertFalse(forward(kind: .failure, perKind: ["failure": true],
                               quietEnabled: true, now: localTime(23, 30)))
        // Outside quiet hours ⇒ allowed.
        XCTAssertTrue(forward(kind: .failure, perKind: ["failure": true],
                              quietEnabled: true, now: localTime(12, 0)))
    }
}
