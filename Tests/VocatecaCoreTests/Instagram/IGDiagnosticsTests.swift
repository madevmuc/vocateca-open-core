import XCTest
@testable import VocatecaCore

/// Feature D (#9) — `IGDiagnostics.assemble` health computation.
final class IGDiagnosticsTests: XCTestCase {

    private func acct(_ id: String, _ status: AccountHealthStatus) -> InstagramAccount {
        InstagramAccount(accountId: id, poolPosition: 0, healthStatus: status, failedAttempts: 0)
    }

    func testEmptyPoolIsHealthy() {
        let r = IGDiagnostics.assemble(accounts: [])
        XCTAssertTrue(r.healthy)
        XCTAssertTrue(r.accounts.isEmpty)
        XCTAssertTrue(r.summary.contains("no accounts"))
    }

    func testAllOkIsHealthy() {
        let r = IGDiagnostics.assemble(accounts: [acct("a", .ok), acct("b", .transient)])
        XCTAssertTrue(r.healthy, "transient does not flip health")
        XCTAssertEqual(r.accounts.count, 2)
    }

    func testSuspendedIsUnhealthy() {
        let r = IGDiagnostics.assemble(accounts: [acct("a", .ok), acct("b", .suspended)])
        XCTAssertFalse(r.healthy)
    }

    func testReauthNeededIsUnhealthy() {
        let r = IGDiagnostics.assemble(accounts: [acct("a", .reauthNeeded)])
        XCTAssertFalse(r.healthy)
        XCTAssertEqual(r.accounts.first?.status, "re_auth_needed")
    }
}
