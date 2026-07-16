import XCTest
@testable import VocatecaCore

/// Tests for the pure global storage-cap eviction policy (no I/O, fixed inputs).
final class MediaCapPolicyTests: XCTestCase {

    private func entry(_ guid: String, size: Int64, daysAgo: Double) -> MediaCapPolicy.FileEntry {
        MediaCapPolicy.FileEntry(
            guid: guid, path: "/tmp/\(guid).mp3", sizeBytes: size,
            mtime: Date(timeIntervalSinceNow: -daysAgo * 86_400))
    }

    // MARK: - Under cap → evict none

    func testUnderCapEvictsNothing() {
        let entries = [
            entry("a", size: 1_000_000_000, daysAgo: 10),
            entry("b", size: 1_000_000_000, daysAgo: 5),
        ]
        let capBytes = MediaCapPolicy.capBytes(forGb: 10) // 10 GB, total is 2 GB
        let decision = MediaCapPolicy.decide(entries: entries, capBytes: capBytes)
        XCTAssertTrue(decision.toEvict.isEmpty)
        XCTAssertEqual(decision.freedBytes, 0)
    }

    func testExactlyAtCapEvictsNothing() {
        let entries = [entry("a", size: 5_000_000_000, daysAgo: 1)]
        let decision = MediaCapPolicy.decide(entries: entries, capBytes: 5_000_000_000)
        XCTAssertTrue(decision.toEvict.isEmpty)
    }

    // MARK: - Over cap → evict oldest-first until under

    func testOverCapEvictsOldestFirstUntilUnderCap() {
        // 3 files, 4 GB each = 12 GB total, cap = 10 GB → must evict the single
        // oldest file (4 GB) to get to 8 GB, which is <= cap.
        let entries = [
            entry("newest", size: 4_000_000_000, daysAgo: 1),
            entry("middle", size: 4_000_000_000, daysAgo: 5),
            entry("oldest", size: 4_000_000_000, daysAgo: 10),
        ]
        let capBytes = MediaCapPolicy.capBytes(forGb: 10)
        let decision = MediaCapPolicy.decide(entries: entries, capBytes: capBytes)
        XCTAssertEqual(decision.toEvict.map(\.guid), ["oldest"])
        XCTAssertEqual(decision.freedBytes, 4_000_000_000)
    }

    func testOverCapEvictsMultipleOldestUntilUnderCap() {
        // 4 files, 3 GB each = 12 GB, cap = 4 GB → must evict the three oldest
        // (down to 3 GB), keeping only the newest.
        let entries = [
            entry("newest", size: 3_000_000_000, daysAgo: 1),
            entry("second", size: 3_000_000_000, daysAgo: 3),
            entry("third",  size: 3_000_000_000, daysAgo: 6),
            entry("oldest", size: 3_000_000_000, daysAgo: 9),
        ]
        let capBytes = MediaCapPolicy.capBytes(forGb: 4)
        let decision = MediaCapPolicy.decide(entries: entries, capBytes: capBytes)
        XCTAssertEqual(decision.toEvict.map(\.guid), ["oldest", "third", "second"])
        XCTAssertEqual(decision.freedBytes, 9_000_000_000)
    }

    func testTiesBrokenByGuidForDeterminism() {
        let sameMtime = Date(timeIntervalSinceNow: -5 * 86_400)
        let entries = [
            MediaCapPolicy.FileEntry(guid: "z", path: "/tmp/z.mp3", sizeBytes: 2_000_000_000, mtime: sameMtime),
            MediaCapPolicy.FileEntry(guid: "a", path: "/tmp/a.mp3", sizeBytes: 2_000_000_000, mtime: sameMtime),
        ]
        // Cap of 2 GB (both entries = 4 GB total) → evict exactly one; the tie on
        // mtime is broken by guid ascending, so "a" goes first.
        let decision = MediaCapPolicy.decide(entries: entries, capBytes: 2_000_000_000)
        XCTAssertEqual(decision.toEvict.map(\.guid), ["a"])
    }

    // MARK: - Near-full threshold

    func testNearFullAtNinetyPercentThreshold() {
        let entries = [entry("a", size: 9_000_000_000, daysAgo: 1)]
        XCTAssertTrue(MediaCapPolicy.isNearFull(entries: entries, capBytes: 10_000_000_000))
    }

    func testNotNearFullBelowThreshold() {
        let entries = [entry("a", size: 8_000_000_000, daysAgo: 1)]
        XCTAssertFalse(MediaCapPolicy.isNearFull(entries: entries, capBytes: 10_000_000_000))
    }

    func testNearFullDisabledWhenCapIsZero() {
        let entries = [entry("a", size: 1, daysAgo: 1)]
        XCTAssertFalse(MediaCapPolicy.isNearFull(entries: entries, capBytes: 0))
    }

    // MARK: - Empty input

    func testEmptyEntriesNeverEvictsOrWarns() {
        let decision = MediaCapPolicy.decide(entries: [], capBytes: 1)
        XCTAssertTrue(decision.toEvict.isEmpty)
        XCTAssertFalse(MediaCapPolicy.isNearFull(entries: [], capBytes: 1))
    }

    // MARK: - 50%-of-available safety clamp (2026-07-16)

    /// Configured cap BELOW the 50%-ceiling is honoured verbatim.
    func testEffectiveCapHonoursConfiguredWhenUnderCeiling() {
        // free 100 GB + 0 media ⇒ ceiling 50 GB; configured 10 GB stays 10 GB.
        let eff = MediaCapPolicy.effectiveCapBytes(
            configuredGb: 10, freeDiskBytes: 100_000_000_000, currentMediaBytes: 0)
        XCTAssertEqual(eff, 10_000_000_000)
    }

    /// Configured cap ABOVE the ceiling is clamped to 50% of (free + current media).
    func testEffectiveCapClampsToHalfOfAddressable() {
        // free 20 GB + 10 GB media ⇒ addressable 30 GB ⇒ ceiling 15 GB.
        // Configured 200 GB is clamped down to 15 GB.
        let eff = MediaCapPolicy.effectiveCapBytes(
            configuredGb: 200, freeDiskBytes: 20_000_000_000, currentMediaBytes: 10_000_000_000)
        XCTAssertEqual(eff, 15_000_000_000)
        XCTAssertEqual(MediaCapPolicy.maxAllowedCapGb(
            freeDiskBytes: 20_000_000_000, currentMediaBytes: 10_000_000_000), 15)
    }

    /// Unknown free disk (probe failed) disables the clamp — never shrinks the
    /// cap to zero on a failed statfs.
    func testEffectiveCapUnclampedWhenDiskUnknown() {
        let eff = MediaCapPolicy.effectiveCapBytes(
            configuredGb: 50, freeDiskBytes: 0, currentMediaBytes: 0)
        XCTAssertEqual(eff, 50_000_000_000)
        XCTAssertNil(MediaCapPolicy.maxAllowedCapGb(freeDiskBytes: 0, currentMediaBytes: 0))
    }
}
