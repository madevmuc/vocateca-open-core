import XCTest
@testable import VocatecaCore

// MARK: - ResumeDecisionTests
//
// Full truth-table for `resumeDecision(partSize:statusCode:serverValidator:
// storedValidator:expectedLength:)`.
//
// No network, no filesystem — all pure-function calls.

final class ResumeDecisionTests: XCTestCase {

    // MARK: - Helpers

    private let matchingETag = Validator(etag: "\"abc123\"", lastModified: nil)
    private let differentETag = Validator(etag: "\"xyz789\"", lastModified: nil)
    private let matchingLM   = Validator(etag: nil, lastModified: "Mon, 01 Jan 2024 00:00:00 GMT")
    private let differentLM  = Validator(etag: nil, lastModified: "Tue, 02 Jan 2024 00:00:00 GMT")
    private let noValidator: Validator? = nil

    // MARK: - 206 + matching validator → appendFrom

    func test206MatchingETagAppendsFromPartSize() {
        let result = resumeDecision(
            partSize: 512_000,
            statusCode: 206,
            serverValidator: matchingETag,
            storedValidator: matchingETag,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .appendFrom(512_000))
    }

    func test206MatchingETagAppendsFromZero() {
        // partSize=0 with 206 (unusual but handled)
        let result = resumeDecision(
            partSize: 0,
            statusCode: 206,
            serverValidator: matchingETag,
            storedValidator: matchingETag,
            expectedLength: nil
        )
        XCTAssertEqual(result, .appendFrom(0))
    }

    func test206MatchingLastModifiedAppendsFromPartSize() {
        let result = resumeDecision(
            partSize: 1_024_000,
            statusCode: 206,
            serverValidator: matchingLM,
            storedValidator: matchingLM,
            expectedLength: 5_000_000
        )
        XCTAssertEqual(result, .appendFrom(1_024_000))
    }

    // MARK: - 206 + no validators → appendFrom (trust the 206)

    func test206BothValidatorsNilAppendsFromPartSize() {
        let result = resumeDecision(
            partSize: 256_000,
            statusCode: 206,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .appendFrom(256_000))
    }

    func test206NoStoredValidatorAppendsFromPartSize() {
        // First-ever download attempt (no sidecar yet) but 206 received.
        let result = resumeDecision(
            partSize: 0,
            statusCode: 206,
            serverValidator: matchingETag,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .appendFrom(0))
    }

    // MARK: - 206 + validator mismatch → restart

    func test206ETagMismatchRestartsDownload() {
        let result = resumeDecision(
            partSize: 512_000,
            statusCode: 206,
            serverValidator: differentETag,
            storedValidator: matchingETag,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    func test206LastModifiedMismatchRestartsDownload() {
        let result = resumeDecision(
            partSize: 512_000,
            statusCode: 206,
            serverValidator: differentLM,
            storedValidator: matchingLM,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }

    func test206StoredValidatorButServerHasNoneRestartsDownload() {
        // Server returned no ETag / Last-Modified; we can't confirm identity.
        let result = resumeDecision(
            partSize: 256_000,
            statusCode: 206,
            serverValidator: noValidator,
            storedValidator: matchingETag,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }

    // MARK: - 200 → always restart

    func test200WithNilValidatorsRestartsDownload() {
        let result = resumeDecision(
            partSize: 0,
            statusCode: 200,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }

    func test200WithMatchingValidatorRestartsDownload() {
        // Even if validators match, a 200 means server returned full content.
        let result = resumeDecision(
            partSize: 512_000,
            statusCode: 200,
            serverValidator: matchingETag,
            storedValidator: matchingETag,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    func test200WithNoPartFileRestartsDownload() {
        let result = resumeDecision(
            partSize: 0,
            statusCode: 200,
            serverValidator: matchingETag,
            storedValidator: noValidator,
            expectedLength: 5_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    // MARK: - 416 → finalize when size matches, restart otherwise

    func test416WithKnownExpectedLengthAndMatchingSizeFinalizesDownload() {
        let result = resumeDecision(
            partSize: 1_000_000,
            statusCode: 416,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .finalizeAlreadyComplete)
    }

    func test416PartSizeExceedsExpectedLengthFinalizesDownload() {
        // Part > expected is normally caught by the partSize>expected guard, but
        // for 416 the guard fires first and returns .restart; here we test the
        // 416 branch at partSize == expected.
        let result = resumeDecision(
            partSize: 999_999,
            statusCode: 416,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: 999_999
        )
        XCTAssertEqual(result, .finalizeAlreadyComplete)
    }

    func test416WithNilExpectedLengthRestartsDownload() {
        // Can't confirm completeness without knowing expected size.
        let result = resumeDecision(
            partSize: 1_000_000,
            statusCode: 416,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }

    func test416WithPartSizeSmallerThanExpectedRestartsDownload() {
        // 416 but we thought we had less than the full file — server's range
        // is not satisfiable for a different reason; restart.
        let result = resumeDecision(
            partSize: 500_000,
            statusCode: 416,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    // MARK: - Part larger than expectedLength → restart (guard fires first)

    func testPartLargerThanExpectedLengthRestarts() {
        let result = resumeDecision(
            partSize: 2_000_000,
            statusCode: 206,
            serverValidator: matchingETag,
            storedValidator: matchingETag,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    func testPartLargerThanExpectedLengthRestartsEvenWith200() {
        let result = resumeDecision(
            partSize: 99_999_999,
            statusCode: 200,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    func testPartLargerThanExpectedLengthRestartsEvenWith416() {
        let result = resumeDecision(
            partSize: 1_000_001,
            statusCode: 416,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: 1_000_000
        )
        XCTAssertEqual(result, .restart)
    }

    // MARK: - Validator.matches edge cases

    func testValidatorMatchesIdenticalETags() {
        let a = Validator(etag: "\"v1\"", lastModified: "Mon")
        let b = Validator(etag: "\"v1\"", lastModified: "Tue")  // LM differs but ETag wins
        XCTAssertTrue(a.matches(b))
    }

    func testValidatorDoesNotMatchDifferentETags() {
        let a = Validator(etag: "\"v1\"", lastModified: nil)
        let b = Validator(etag: "\"v2\"", lastModified: nil)
        XCTAssertFalse(a.matches(b))
    }

    func testValidatorFallsBackToLastModifiedWhenNoETag() {
        let a = Validator(etag: nil, lastModified: "Mon, 01 Jan 2024 00:00:00 GMT")
        let b = Validator(etag: nil, lastModified: "Mon, 01 Jan 2024 00:00:00 GMT")
        XCTAssertTrue(a.matches(b))
    }

    func testValidatorDoesNotMatchWhenBothFieldsNil() {
        let a = Validator(etag: nil, lastModified: nil)
        let b = Validator(etag: nil, lastModified: nil)
        XCTAssertFalse(a.matches(b))
    }

    func testValidatorDoesNotMatchMixedNilETags() {
        // One side has ETag, other has none → no shared field for ETag comparison.
        // LM is also nil, so overall mismatch.
        let a = Validator(etag: "\"v1\"", lastModified: nil)
        let b = Validator(etag: nil,     lastModified: nil)
        XCTAssertFalse(a.matches(b))
    }

    // MARK: - Other status codes → restart

    func test5xxStatusCodeRestarts() {
        let result = resumeDecision(
            partSize: 256_000,
            statusCode: 503,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }

    func test404StatusCodeRestarts() {
        let result = resumeDecision(
            partSize: 256_000,
            statusCode: 404,
            serverValidator: noValidator,
            storedValidator: noValidator,
            expectedLength: nil
        )
        XCTAssertEqual(result, .restart)
    }
}
