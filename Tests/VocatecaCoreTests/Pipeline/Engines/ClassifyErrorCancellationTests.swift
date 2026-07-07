import XCTest
import Foundation
@testable import VocatecaCore

/// Stability wave 1 — Bug B (H1): a Stop / hard-pause mid-download must NOT
/// permanently fail the episode. `URLSessionDownloader.classifyError` used to
/// drop `URLError.cancelled` / `CancellationError` into `default:` → `.permanent`
/// → `recordFailure(retry:false)` → `failed`. It must now classify both as the
/// dedicated `.cancelled` category so the pipeline resets the row to `pending`.
final class ClassifyErrorCancellationTests: XCTestCase {

    func testURLErrorCancelledIsCancelled() {
        let classified = URLSessionDownloader.classifyError(URLError(.cancelled))
        guard case .cancelled = classified else {
            return XCTFail("URLError.cancelled must classify as .cancelled, got \(classified)")
        }
    }

    func testSwiftCancellationErrorIsCancelled() {
        let classified = URLSessionDownloader.classifyError(CancellationError())
        guard case .cancelled = classified else {
            return XCTFail("CancellationError must classify as .cancelled, got \(classified)")
        }
    }

    // Regression guard: genuinely transient / permanent URL errors keep their
    // existing classification (the new .cancelled branch must not swallow them).
    func testTimeoutStaysTransient() {
        guard case .transient = URLSessionDownloader.classifyError(URLError(.timedOut)) else {
            return XCTFail(".timedOut must remain .transient")
        }
    }

    func testUnsupportedURLStaysPermanent() {
        guard case .permanent = URLSessionDownloader.classifyError(URLError(.unsupportedURL)) else {
            return XCTFail(".unsupportedURL must remain .permanent")
        }
    }
}
