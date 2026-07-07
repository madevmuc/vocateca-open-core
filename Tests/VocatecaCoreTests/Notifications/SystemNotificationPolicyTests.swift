import XCTest
@testable import VocatecaCore

/// TDD tests for ``SystemNotificationPolicy``.
///
/// ## Coverage
/// - Explicit `perKind` override wins over the default (both true→true and false→false).
/// - Absent key falls back to ``SystemNotificationPolicy/defaultForward(for:isPro:)``.
/// - `dailySummary` defaults to `true` for everyone (its emission is already Free —
///   product-owner clarification: the only Free↔Pro difference is automatic
///   transcription — so gating just the forward-toggle would leave Free users
///   unable to turn off a notification they already receive).
/// - `failure` (representative non-summary kind) defaults `false` regardless of tier.
/// - `isPro` does not change defaults for non-summary kinds.
///
/// ## Target choice
/// `SystemNotificationPolicy` lives in `VocatecaCore` (so the pure logic can be
/// tested without any UI imports), and these tests live in `VocatecaCoreTests`
/// which already imports `VocatecaCore`.  No `Package.swift` edits required.
final class SystemNotificationPolicyTests: XCTestCase {

    // MARK: - Helpers

    private func forward(
        _ kind: NotifKindKey,
        isPro: Bool = false,
        perKind: [String: Bool] = [:]
    ) -> Bool {
        SystemNotificationPolicy.shouldForward(kind: kind, isPro: isPro, perKind: perKind)
    }

    // MARK: - Per-kind explicit override wins

    func testExplicitTrueOverridesDefault() {
        // failure defaults false; an explicit true should flip it.
        XCTAssertTrue(
            forward(.failure, isPro: false, perKind: ["failure": true]),
            "Explicit perKind=true must override the default=false for .failure"
        )
    }

    func testExplicitFalseOverridesDefault() {
        // dailySummary defaults true for everyone; an explicit false must suppress it.
        XCTAssertFalse(
            forward(.dailySummary, isPro: true, perKind: ["dailySummary": false]),
            "Explicit perKind=false must override the default=true for .dailySummary"
        )
    }

    func testExplicitKeyForOtherKindDoesNotAffectQueriedKind() {
        // A perKind entry for "failure" must NOT affect "runFinished".
        XCTAssertFalse(
            forward(.runFinished, isPro: false, perKind: ["failure": true]),
            "perKind override for 'failure' must not bleed into 'runFinished'"
        )
    }

    // MARK: - Absent key → default

    func testAbsentKeyUsesDefault_failure() {
        // No entry in perKind → should return default (false).
        XCTAssertFalse(forward(.failure, isPro: false, perKind: [:]))
        XCTAssertFalse(forward(.failure, isPro: true,  perKind: [:]))
    }

    func testAbsentKeyUsesDefault_dailySummaryFree() {
        // No entry, Free user → true (dailySummary is Free — same default as Pro).
        XCTAssertTrue(forward(.dailySummary, isPro: false, perKind: [:]))
    }

    func testAbsentKeyUsesDefault_dailySummaryPro() {
        // No entry, Pro user → true.
        XCTAssertTrue(forward(.dailySummary, isPro: true, perKind: [:]))
    }

    // MARK: - Default: dailySummary

    func testDefaultForward_dailySummary_pro() {
        XCTAssertTrue(SystemNotificationPolicy.defaultForward(for: .dailySummary, isPro: true))
    }

    func testDefaultForward_dailySummary_free() {
        // dailySummary is Free — same true default as Pro (no entitlement check).
        XCTAssertTrue(SystemNotificationPolicy.defaultForward(for: .dailySummary, isPro: false))
    }

    // MARK: - Default: non-summary kinds always false

    func testDefaultForward_failure_alwaysFalse() {
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .failure, isPro: false))
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .failure, isPro: true))
    }

    func testDefaultForward_runFinished_alwaysFalse() {
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .runFinished, isPro: false))
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .runFinished, isPro: true))
    }

    func testDefaultForward_newEpisode_alwaysFalse() {
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .newEpisode, isPro: false))
        XCTAssertFalse(SystemNotificationPolicy.defaultForward(for: .newEpisode, isPro: true))
    }

    func testDefaultForward_allNonSummaryKindsAreFalse() {
        let nonSummary: [NotifKindKey] = [
            .accountSuspended, .accountReauth, .keywordHit,
            .runFinished, .backfillDone, .failure, .newEpisode,
            .skippedNoSpeech
        ]
        for kind in nonSummary {
            for isPro in [false, true] {
                XCTAssertFalse(
                    SystemNotificationPolicy.defaultForward(for: kind, isPro: isPro),
                    "\(kind.rawValue) should default false regardless of isPro=\(isPro)"
                )
            }
        }
    }

    // MARK: - isPro does not change defaults for non-summary kinds

    func testIsProDoesNotChangeNonSummaryDefaults() {
        // For every non-summary kind, isPro=true must NOT flip the default.
        let nonSummary: [NotifKindKey] = [
            .accountSuspended, .accountReauth, .keywordHit,
            .runFinished, .backfillDone, .failure, .newEpisode,
            .skippedNoSpeech
        ]
        for kind in nonSummary {
            XCTAssertEqual(
                forward(kind, isPro: false),
                forward(kind, isPro: true),
                "isPro should not change default for non-summary kind \(kind.rawValue)"
            )
        }
    }

    // MARK: - NotifKindKey is CaseIterable (covers all 12 kinds)

    func testNotifKindKeyAllCasesCount() {
        // 10 pre-existing kinds + storageWarning + mediaEvicted (media-retention brief).
        XCTAssertEqual(NotifKindKey.allCases.count, 12, "NotifKindKey should expose 12 cases")
    }

    func testModelReadyForwardsByDefault() {
        // A finished multi-GB model download is a wait-worthy event → system by default.
        XCTAssertTrue(SystemNotificationPolicy.defaultForward(for: .modelReady, isPro: false))
        XCTAssertTrue(SystemNotificationPolicy.defaultForward(for: .modelReady, isPro: true))
    }

    func testNotifKindKeyRawValuesAreDistinct() {
        let raw = NotifKindKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count, "All NotifKindKey raw values must be distinct")
    }
}
