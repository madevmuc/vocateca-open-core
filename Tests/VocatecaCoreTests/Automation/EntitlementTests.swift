import XCTest
@testable import VocatecaCore

/// Tests for ``EntitlementStatus``, ``LocalStubEntitlementProvider``,
/// and ``isAutomationAllowed(_:)``.
///
/// Key property under test: fail-open semantics.
/// `.active` and `.unknown` → automation allowed.
/// `.expired` and `.cancelled` → automation blocked.
final class EntitlementTests: XCTestCase {

    // MARK: - isAutomationAllowed truth table

    /// Exhaustive truth table for all four EntitlementStatus cases.
    func testIsAutomationAllowedTruthTable() {
        // allowed
        XCTAssertTrue(isAutomationAllowed(.active),   ".active must allow automation")
        XCTAssertTrue(isAutomationAllowed(.unknown),  ".unknown must allow automation (fail-open grace)")
        // blocked
        XCTAssertFalse(isAutomationAllowed(.expired),   ".expired must block automation")
        XCTAssertFalse(isAutomationAllowed(.cancelled), ".cancelled must block automation")
    }

    /// Fail-open: `.unknown` (server unreachable) allows automation.
    /// This is the critical property: a network outage must not disable automation
    /// for paying users. Only a *definitive* non-active state blocks automation.
    func testFailOpenUnknown() {
        XCTAssertTrue(isAutomationAllowed(.unknown),
            "Fail-open: .unknown (server unreachable) must allow automation, not disable it")
    }

    /// Expired subscription blocks automation.
    func testExpiredBlocksAutomation() {
        XCTAssertFalse(isAutomationAllowed(.expired))
    }

    /// Cancelled subscription blocks automation.
    func testCancelledBlocksAutomation() {
        XCTAssertFalse(isAutomationAllowed(.cancelled))
    }

    // MARK: - LocalStubEntitlementProvider

    func testStubProviderDefaultIsActive() async {
        let provider = LocalStubEntitlementProvider()
        let status = await provider.current()
        XCTAssertEqual(status, .active)
    }

    func testStubProviderReturnsSpecifiedStatus() async {
        for expected in [EntitlementStatus.active, .expired, .cancelled, .unknown] {
            let provider = LocalStubEntitlementProvider(status: expected)
            let got = await provider.current()
            XCTAssertEqual(got, expected, "LocalStubEntitlementProvider must return the fixed status")
        }
    }

    // MARK: - EntitlementStatus rawValues

    func testRawValues() {
        XCTAssertEqual(EntitlementStatus.active.rawValue,    "active")
        XCTAssertEqual(EntitlementStatus.expired.rawValue,   "expired")
        XCTAssertEqual(EntitlementStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(EntitlementStatus.unknown.rawValue,   "unknown")
    }

    func testRawValueRoundTrip() {
        for status in [EntitlementStatus.active, .expired, .cancelled, .unknown] {
            let raw = status.rawValue
            let back = EntitlementStatus(rawValue: raw)
            XCTAssertEqual(back, status, "rawValue round-trip failed for \(raw)")
        }
    }
}
