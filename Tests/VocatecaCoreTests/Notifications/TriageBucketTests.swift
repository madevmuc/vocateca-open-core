import XCTest
@testable import VocatecaCore

/// Unit tests for the kind→bucket triage mapping and the resolve transition.
///
/// Pure `VocatecaCore` logic — no SwiftUI/AppKit — so the classification the UI
/// depends on is locked down here.
final class TriageBucketTests: XCTestCase {

    // MARK: - Base bucket (kind classification, ignoring resolved)

    func testNeedsActionKinds() {
        XCTAssertEqual(NotifKindKey.failure.baseTriageBucket, .needsAction)
        XCTAssertEqual(NotifKindKey.skippedNoSpeech.baseTriageBucket, .needsAction)
        XCTAssertEqual(NotifKindKey.accountReauth.baseTriageBucket, .needsAction)
        XCTAssertEqual(NotifKindKey.accountSuspended.baseTriageBucket, .needsAction)
    }

    func testNewKinds() {
        XCTAssertEqual(NotifKindKey.newEpisode.baseTriageBucket, .new)
        XCTAssertEqual(NotifKindKey.keywordHit.baseTriageBucket, .new)
    }

    func testDoneKinds() {
        XCTAssertEqual(NotifKindKey.runFinished.baseTriageBucket, .done)
        XCTAssertEqual(NotifKindKey.backfillDone.baseTriageBucket, .done)
        XCTAssertEqual(NotifKindKey.dailySummary.baseTriageBucket, .done)
        XCTAssertEqual(NotifKindKey.modelReady.baseTriageBucket, .done)
    }

    /// Every kind must map to exactly one bucket (the switch is exhaustive) —
    /// guards against a future kind silently defaulting.
    func testEveryKindMapsToABucket() {
        for kind in NotifKindKey.allCases {
            let bucket = kind.baseTriageBucket
            XCTAssertTrue(TriageBucket.allCases.contains(bucket),
                          "\(kind) mapped to an unknown bucket")
        }
    }

    // MARK: - Resolve transition

    func testUnresolvedActionableStaysInItsBucket() {
        XCTAssertEqual(NotifKindKey.failure.triageBucket(isResolved: false), .needsAction)
        XCTAssertEqual(NotifKindKey.newEpisode.triageBucket(isResolved: false), .new)
    }

    func testResolvingMovesActionableItemToDone() {
        // A failure the user acted on (Retry) → Done.
        XCTAssertEqual(NotifKindKey.failure.triageBucket(isResolved: true), .done)
        // A new episode the user transcribed/ignored → Done.
        XCTAssertEqual(NotifKindKey.newEpisode.triageBucket(isResolved: true), .done)
        // An account re-auth acted on → Done.
        XCTAssertEqual(NotifKindKey.accountReauth.triageBucket(isResolved: true), .done)
    }

    func testResolvedInformationalStaysInDone() {
        // Informational kinds are already Done; resolving is a no-op on bucket.
        XCTAssertEqual(NotifKindKey.runFinished.triageBucket(isResolved: false), .done)
        XCTAssertEqual(NotifKindKey.runFinished.triageBucket(isResolved: true), .done)
    }

    // MARK: - Segment metadata

    func testSegmentOrderAndDefault() {
        // Display order = needsAction, new, done (default is first).
        XCTAssertEqual(TriageBucket.allCases, [.needsAction, .new, .done])
        XCTAssertEqual(TriageBucket.allCases.first, .needsAction)
    }
}
