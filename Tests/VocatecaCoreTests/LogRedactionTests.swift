import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - LogRedactionTests
//
// Unit tests for LogRedaction — the pure, testable redaction applied only to
// the copy/export path (in-app log viewing stays full).

final class LogRedactionTests: XCTestCase {

    private func makeLine() -> LogLine {
        LogLine(
            date: Date(),
            level: .info,
            component: "Ingest",
            message: "downloaded to /Users/alice/Music/ep.mp3 from https://feeds.example.com/x",
            context: [
                ("title", "My Secret Ep"),
                ("slug", "my-show"),
                ("count", "3"),
                ("status", "done")
            ]
        )
    }

    // MARK: - Sensitive keys masked, safe keys pass through

    func testRedactMasksSensitiveContextValues() {
        let line = makeLine()
        let redacted = LogRedaction.redact(line)

        XCTAssertTrue(redacted.contains("title=<redacted>"), "title value should be masked: \(redacted)")
        XCTAssertTrue(redacted.contains("slug=<redacted>"), "slug value should be masked: \(redacted)")
        XCTAssertFalse(redacted.contains("My Secret Ep"), "raw title value must not leak: \(redacted)")
        XCTAssertFalse(redacted.contains("my-show"), "raw slug value must not leak: \(redacted)")
    }

    func testRedactKeepsSafeContextValues() {
        let line = makeLine()
        let redacted = LogRedaction.redact(line)

        XCTAssertTrue(redacted.contains("count=3"), "safe key 'count' should pass through unchanged: \(redacted)")
        XCTAssertTrue(redacted.contains("status=done"), "safe key 'status' should pass through unchanged: \(redacted)")
    }

    // MARK: - Message scrubbing (URL + absolute path)

    func testRedactScrubsPathAndURLFromMessage() {
        let line = makeLine()
        let redacted = LogRedaction.redact(line)

        XCTAssertTrue(redacted.contains("<redacted-path>"), "absolute path should be scrubbed: \(redacted)")
        XCTAssertTrue(redacted.contains("<redacted-url>"), "URL should be scrubbed: \(redacted)")
        XCTAssertFalse(redacted.contains("/Users/alice"), "raw home path must not leak: \(redacted)")
        XCTAssertFalse(redacted.contains("feeds.example.com"), "raw host must not leak: \(redacted)")
    }

    // MARK: - L-2: email scrubbing (free-text message AND context values)

    func testScrubMasksEmailAddressInMessageText() {
        let scrubbed = LogRedaction.scrub("Signed in as matthias@vocateca.com just now")
        XCTAssertTrue(scrubbed.contains("[email]"), "email should be masked: \(scrubbed)")
        XCTAssertFalse(scrubbed.contains("matthias@vocateca.com"), "raw email must not leak: \(scrubbed)")
    }

    func testRedactMasksEmailContextValueViaSensitiveKeys() {
        // AccountStore now logs email as a context tuple (not free text) —
        // confirm the pre-existing "email" sensitiveKeys entry still masks it.
        let line = LogLine(
            date: Date(), level: .info, component: "Account",
            message: "Signed in",
            context: [("email", "matthias@vocateca.com"), ("entitlement", "active")]
        )
        let redacted = LogRedaction.redact(line)
        XCTAssertTrue(redacted.contains("email=<redacted>"), "email context value should be masked: \(redacted)")
        XCTAssertFalse(redacted.contains("matthias@vocateca.com"), "raw email must not leak: \(redacted)")
        XCTAssertTrue(redacted.contains("entitlement=active"), "non-sensitive context value should pass through: \(redacted)")
    }

    func testScrubDoesNotAlterTextWithNoEmail() {
        let text = "downloaded episode 3 successfully"
        XCTAssertEqual(LogRedaction.scrub(text), text)
    }

    // MARK: - Timestamp / level / component preserved

    func testRedactKeepsLevelAndComponent() {
        let line = makeLine()
        let redacted = LogRedaction.redact(line)

        XCTAssertTrue(redacted.contains("[INFO]"))
        XCTAssertTrue(redacted.contains("[Ingest]"))
    }

    // MARK: - Regression guard: non-redacted formatting unchanged

    func testFormattedIsUnchangedByRedactionAddition() {
        let line = makeLine()
        let formatted = line.formatted

        XCTAssertTrue(formatted.contains("title=My Secret Ep"))
        XCTAssertTrue(formatted.contains("slug=my-show"))
        XCTAssertTrue(formatted.contains("count=3"))
        XCTAssertTrue(formatted.contains("status=done"))
        XCTAssertTrue(formatted.contains("/Users/alice/Music/ep.mp3"))
        XCTAssertTrue(formatted.contains("https://feeds.example.com/x"))
        XCTAssertTrue(formatted.contains("[INFO]"))
        XCTAssertTrue(formatted.contains("[Ingest]"))
    }

    // MARK: - copyPayload(redacted:) integration

    func testCopyPayloadRedactedMasksBufferedLines() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logredaction-test-\(UUID().uuidString).log")
        let store = LogStore(maxLines: 100, maxFileSizeBytes: 1_048_576, logURL: url)

        Log.info(
            "downloaded to /Users/alice/Music/ep.mp3 from https://feeds.example.com/x",
            component: "Ingest",
            context: [("title", "My Secret Ep"), ("slug", "my-show"), ("count", "3")],
            store: store
        )

        let redactedPayload = store.copyPayload(redacted: true, systemInfo: "Home: /Users/alice")
        XCTAssertFalse(redactedPayload.contains("My Secret Ep"))
        XCTAssertFalse(redactedPayload.contains("/Users/alice"))
        XCTAssertFalse(redactedPayload.contains("feeds.example.com"))
        XCTAssertTrue(redactedPayload.contains("title=<redacted>"))
        XCTAssertTrue(redactedPayload.contains("count=3"))

        let fullPayload = store.copyPayload(redacted: false, systemInfo: "Home: /Users/alice")
        XCTAssertTrue(fullPayload.contains("My Secret Ep"))
        XCTAssertTrue(fullPayload.contains("/Users/alice"))
    }
}
