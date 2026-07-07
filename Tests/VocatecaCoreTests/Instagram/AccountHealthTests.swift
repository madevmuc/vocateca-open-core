import XCTest
@testable import VocatecaCore

/// Tests for ``AccountHealthClassifier`` — classification and escalation ladder.
final class AccountHealthTests: XCTestCase {

    // MARK: - Helpers

    private typealias Classifier = AccountHealthClassifier

    // MARK: - Classification: 429 / transient

    func testHTTP429ClassifiesAsTransient() {
        let result = Classifier.classify(errorText: "", httpStatus: 429)
        XCTAssertEqual(result, .transient)
    }

    func testHTTP429TakesPriorityOverErrorText() {
        // Even if errorText contains a re-auth phrase, 429 wins.
        let result = Classifier.classify(errorText: "login required", httpStatus: 429)
        XCTAssertEqual(result, .transient)
    }

    // MARK: - Classification: re-auth / checkpoint

    func testLoginRequiredClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Login required", httpStatus: nil),
            .reauthNeeded
        )
    }

    func testNotLoggedInClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Not logged in to instagram", httpStatus: nil),
            .reauthNeeded
        )
    }

    func testSessionExpiredClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Session expired, please re-login", httpStatus: nil),
            .reauthNeeded
        )
    }

    func testCheckpointRequiredClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "checkpoint_required", httpStatus: nil),
            .reauthNeeded
        )
    }

    func testTwoFactorClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "two factor authentication needed", httpStatus: nil),
            .reauthNeeded
        )
    }

    func testPleaseLogInClassifiesAsReauth() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Please log in to continue.", httpStatus: nil),
            .reauthNeeded
        )
    }

    // MARK: - Classification: suspended

    func testAccountDisabledClassifiesAsSuspended() {
        XCTAssertEqual(
            Classifier.classify(errorText: "This account has been disabled", httpStatus: nil),
            .suspended
        )
    }

    func testAccountBannedClassifiesAsSuspended() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Your account has been permanently banned", httpStatus: nil),
            .suspended
        )
    }

    func testViolatesTermsClassifiesAsSuspended() {
        XCTAssertEqual(
            Classifier.classify(errorText: "Your account violates our terms of service", httpStatus: nil),
            .suspended
        )
    }

    // MARK: - Classification: suspended takes priority over re-auth phrases

    func testSuspendedTakesPriorityOverReauth() {
        // If both suspended + re-auth phrases appear, suspended wins (checked first).
        let result = Classifier.classify(
            errorText: "account disabled — please log in to confirm",
            httpStatus: nil
        )
        XCTAssertEqual(result, .suspended)
    }

    // MARK: - Classification: ok (fallthrough)

    func testUnknownErrorFallsThrough() {
        XCTAssertEqual(
            Classifier.classify(errorText: "some random network error", httpStatus: nil),
            .ok
        )
    }

    func testEmptyErrorTextWithOKStatus() {
        XCTAssertEqual(
            Classifier.classify(errorText: "", httpStatus: nil),
            .ok
        )
    }

    func testHTTP200ClassifiesAsOK() {
        // Non-429 HTTP codes fall through to error-text matching (or .ok).
        XCTAssertEqual(
            Classifier.classify(errorText: "", httpStatus: 200),
            .ok
        )
    }

    // MARK: - Classification: case-insensitive

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(
            Classifier.classify(errorText: "LOGIN REQUIRED", httpStatus: nil),
            .reauthNeeded
        )
        XCTAssertEqual(
            Classifier.classify(errorText: "ACCOUNT SUSPENDED", httpStatus: nil),
            .suspended
        )
    }

    // MARK: - Escalation: .ok stays .ok

    func testOKDoesNotEscalate() {
        for attempts in [0, 1, 10, 100] {
            XCTAssertEqual(Classifier.escalate(current: .ok, failedAttempts: attempts), .ok,
                           "ok must never escalate (attempts=\(attempts))")
        }
    }

    // MARK: - Escalation: .suspended stays .suspended

    func testSuspendedDoesNotEscalate() {
        for attempts in [0, 1, 10, 100] {
            XCTAssertEqual(Classifier.escalate(current: .suspended, failedAttempts: attempts), .suspended,
                           "suspended must stay suspended (attempts=\(attempts))")
        }
    }

    // MARK: - Escalation: .transient ladder

    func testTransientBelowThresholdStaysTransient() {
        let threshold = Classifier.transientToReauthThreshold
        for attempts in 0 ..< threshold {
            XCTAssertEqual(Classifier.escalate(current: .transient, failedAttempts: attempts), .transient,
                           "transient must stay transient below threshold (attempts=\(attempts))")
        }
    }

    func testTransientAtThresholdEscalatesToReauth() {
        let threshold = Classifier.transientToReauthThreshold
        XCTAssertEqual(
            Classifier.escalate(current: .transient, failedAttempts: threshold),
            .reauthNeeded,
            "transient must escalate to reauthNeeded at threshold (\(threshold))"
        )
    }

    func testTransientAboveThresholdEscalatesToReauth() {
        let threshold = Classifier.transientToReauthThreshold
        XCTAssertEqual(
            Classifier.escalate(current: .transient, failedAttempts: threshold + 5),
            .reauthNeeded
        )
    }

    // MARK: - Escalation: .reauthNeeded ladder

    func testReauthBelowThresholdStaysReauth() {
        let threshold = Classifier.reauthToSuspendedThreshold
        for attempts in 0 ..< threshold {
            XCTAssertEqual(
                Classifier.escalate(current: .reauthNeeded, failedAttempts: attempts),
                .reauthNeeded,
                "reauthNeeded must stay reauthNeeded below threshold (attempts=\(attempts))"
            )
        }
    }

    func testReauthAtThresholdEscalatesToSuspended() {
        let threshold = Classifier.reauthToSuspendedThreshold
        XCTAssertEqual(
            Classifier.escalate(current: .reauthNeeded, failedAttempts: threshold),
            .suspended,
            "reauthNeeded must escalate to suspended at threshold (\(threshold))"
        )
    }

    func testReauthAboveThresholdEscalatesToSuspended() {
        let threshold = Classifier.reauthToSuspendedThreshold
        XCTAssertEqual(
            Classifier.escalate(current: .reauthNeeded, failedAttempts: threshold + 10),
            .suspended
        )
    }

    // MARK: - Threshold constants are documented values

    func testTransientThresholdIs10() {
        XCTAssertEqual(Classifier.transientToReauthThreshold, 10)
    }

    func testReauthThresholdIs3() {
        XCTAssertEqual(Classifier.reauthToSuspendedThreshold, 3)
    }

    // MARK: - Raw values (for DB storage)

    func testRawValues() {
        XCTAssertEqual(AccountHealthStatus.ok.rawValue, "ok")
        XCTAssertEqual(AccountHealthStatus.reauthNeeded.rawValue, "re_auth_needed")
        XCTAssertEqual(AccountHealthStatus.suspended.rawValue, "suspended")
        XCTAssertEqual(AccountHealthStatus.transient.rawValue, "transient")
    }

    func testRoundTripFromRawValue() {
        for status in AccountHealthStatus.allCases {
            XCTAssertEqual(AccountHealthStatus(rawValue: status.rawValue), status)
        }
    }
}
