import XCTest
@testable import VocatecaQwen

/// Tests for the M11 model-cache integrity check + auto-purge in
/// `QwenProvisioning`. Network-free: it fabricates cache files on disk (under a
/// unique fake model id) and never downloads anything, so it runs in the default
/// suite. Each test cleans up its fabricated directory.
final class QwenProvisioningIntegrityTests: XCTestCase {

    /// A unique, obviously-fake model id so this never collides with a real
    /// cached model on the dev machine.
    private var fakeModelId = ""

    override func setUp() {
        super.setUp()
        fakeModelId = "test-fixtures/qwen-integrity-\(UUID().uuidString)"
    }

    override func tearDown() {
        // Remove anything this test wrote, even on failure.
        try? FileManager.default.removeItem(at: QwenProvisioning.cacheDir(modelId: fakeModelId))
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a `model.safetensors` of `bytes` length into the fake model's
    /// cache dir, creating the directory tree.
    private func writeWeights(bytes: Int) throws {
        let dir = QwenProvisioning.cacheDir(modelId: fakeModelId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let weights = dir.appendingPathComponent("model.safetensors")
        try Data(count: bytes).write(to: weights)
    }

    private func weightsExist() -> Bool {
        FileManager.default.fileExists(
            atPath: QwenProvisioning.cacheDir(modelId: fakeModelId)
                .appendingPathComponent("model.safetensors").path)
    }

    // MARK: - isCached integrity threshold

    func testIsCachedFalseWhenWeightsMissing() {
        XCTAssertFalse(QwenProvisioning.isCached(modelId: fakeModelId))
    }

    func testIsCachedFalseForTruncatedWeights() throws {
        // A 1 KB "model.safetensors" is an aborted download, not a real model.
        try writeWeights(bytes: 1024)
        XCTAssertFalse(QwenProvisioning.isCached(modelId: fakeModelId),
                       "a sub-threshold weights file must NOT count as cached")
    }

    func testIsCachedTrueForFullSizedWeights() throws {
        // At/above the threshold → treated as a real, complete download.
        try writeWeights(bytes: Int(QwenProvisioning.minWeightsBytes))
        XCTAssertTrue(QwenProvisioning.isCached(modelId: fakeModelId))
    }

    // MARK: - purgeIfCorrupt

    func testPurgeRemovesTruncatedCache() throws {
        try writeWeights(bytes: 2048)   // corrupt/partial
        XCTAssertTrue(weightsExist())

        let purged = QwenProvisioning.purgeIfCorrupt(modelId: fakeModelId)

        XCTAssertTrue(purged, "a partial cache should be reported as purged")
        XCTAssertFalse(weightsExist(), "the corrupt cache dir should be gone")
        XCTAssertFalse(QwenProvisioning.isCached(modelId: fakeModelId))
    }

    func testPurgeKeepsIntactCache() throws {
        try writeWeights(bytes: Int(QwenProvisioning.minWeightsBytes) + 1)
        XCTAssertTrue(weightsExist())

        let purged = QwenProvisioning.purgeIfCorrupt(modelId: fakeModelId)

        XCTAssertFalse(purged, "an intact cache must NOT be purged")
        XCTAssertTrue(weightsExist(), "the intact cache must survive")
        XCTAssertTrue(QwenProvisioning.isCached(modelId: fakeModelId))
    }

    func testPurgeNoOpWhenNothingOnDisk() {
        // No directory at all → nothing to purge, no crash.
        XCTAssertFalse(QwenProvisioning.purgeIfCorrupt(modelId: fakeModelId))
    }
}
