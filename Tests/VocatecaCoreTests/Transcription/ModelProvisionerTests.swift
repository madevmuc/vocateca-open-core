import XCTest
@testable import VocatecaCore

/// Unit tests for ``ModelProvisioner`` with an injected fake downloader
/// (spec §8 — no real network / model download).
final class ModelProvisionerTests: XCTestCase {

    private struct ProbeError: Error {}

    func testAlreadyCachedIsReadyWithoutDownloading() async {
        let downloadCalled = LockedFlag()
        let p = ModelProvisioner(
            engineLabel: "Test", sizeGB: 1.0,
            isCached: { true },
            download: { _ in downloadCalled.set() }
        )
        XCTAssertTrue(p.isReady)
        let state = await p.provision()
        XCTAssertEqual(state, .ready)
        XCTAssertFalse(downloadCalled.value, "download must be skipped when cached")
    }

    func testSuccessfulDownloadStreamsProgressThenReady() async {
        let fractions = LockedArray()
        let p = ModelProvisioner(
            engineLabel: "Test", sizeGB: 2.0,
            isCached: { false },
            download: { onProgress in
                onProgress(0.0); onProgress(0.5); onProgress(1.0)
            }
        )
        let state = await p.provision(onProgress: { fractions.append($0) })
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(fractions.values, [0.0, 0.5, 1.0])
    }

    func testProgressIsClampedToUnitInterval() async {
        let fractions = LockedArray()
        let p = ModelProvisioner(
            engineLabel: "Test", sizeGB: 1.0, isCached: { false },
            download: { onProgress in onProgress(-0.3); onProgress(1.7) }
        )
        _ = await p.provision(onProgress: { fractions.append($0) })
        XCTAssertEqual(fractions.values, [0.0, 1.0])
    }

    func testDownloadFailureReportsFailed() async {
        let p = ModelProvisioner(
            engineLabel: "Test", sizeGB: 1.0, isCached: { false },
            download: { _ in throw ProbeError() }
        )
        let state = await p.provision()
        guard case .failed = state else {
            return XCTFail("expected .failed, got \(state)")
        }
    }

    func testCancellationReportsIdleNotFailed() async {
        let p = ModelProvisioner(
            engineLabel: "Test", sizeGB: 1.0, isCached: { false },
            download: { _ in throw CancellationError() }
        )
        let state = await p.provision()
        XCTAssertEqual(state, .idle, "cancellation is retryable, not a failure")
    }
}

// MARK: - Tiny thread-safe test helpers

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var _v = false
    func set() { lock.withLock { _v = true } }
    var value: Bool { lock.withLock { _v } }
}

private final class LockedArray: @unchecked Sendable {
    private let lock = NSLock(); private var _v: [Double] = []
    func append(_ x: Double) { lock.withLock { _v.append(x) } }
    var values: [Double] { lock.withLock { _v } }
}
