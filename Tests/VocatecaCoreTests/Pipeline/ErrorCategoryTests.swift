import XCTest
@testable import VocatecaCore

/// Tests for ``ErrorCategory/classify(phase:message:)`` — the phase→category
/// mapping that keeps the Failed-tab filters meaningful (previously every
/// permanent failure was stored as `unknown`, so all rows fell into "Other").
final class ErrorCategoryTests: XCTestCase {

    func testPhaseDefaults() {
        XCTAssertEqual(ErrorCategory.classify(phase: "download", message: "yt-dlp exited 1"),
                       ErrorCategory.download)
        XCTAssertEqual(ErrorCategory.classify(phase: "downloading", message: "HTTP 403"),
                       ErrorCategory.download)
        XCTAssertEqual(ErrorCategory.classify(phase: "transcribe", message: "whisper-cli crashed"),
                       ErrorCategory.whisper)
        XCTAssertEqual(ErrorCategory.classify(phase: "transcribing", message: "model load failed"),
                       ErrorCategory.whisper)
        XCTAssertEqual(ErrorCategory.classify(phase: "ocr", message: "Vision failed"),
                       ErrorCategory.ocr)
        XCTAssertEqual(ErrorCategory.classify(phase: "library", message: "write failed"),
                       ErrorCategory.disk)
        XCTAssertEqual(ErrorCategory.classify(phase: "weird", message: "???"),
                       ErrorCategory.unknown)
    }

    func testMessageSignalsWinOverPhase() {
        // A disk-full during a download is a disk error, not a download error.
        XCTAssertEqual(ErrorCategory.classify(phase: "download", message: "No space left on device"),
                       ErrorCategory.disk)
        XCTAssertEqual(ErrorCategory.classify(phase: "transcribe", message: "ENOSPC writing temp"),
                       ErrorCategory.disk)
        XCTAssertEqual(ErrorCategory.classify(phase: "download", message: "Media not found (404)"),
                       ErrorCategory.notFound)
        XCTAssertEqual(ErrorCategory.classify(phase: "download", message: "File too large: 413"),
                       ErrorCategory.tooLarge)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(ErrorCategory.classify(phase: "download", message: "DISK FULL"),
                       ErrorCategory.disk)
    }
}
