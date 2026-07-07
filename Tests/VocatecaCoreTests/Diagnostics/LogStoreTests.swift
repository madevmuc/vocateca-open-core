import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - LogStoreTests
//
// Unit tests for LogStore ring buffer, clear, and copyPayload.
// Uses a private LogStore (not .shared) with an injected temp URL.

final class LogStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore(maxLines: Int = 100) -> (LogStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logstore-test-\(UUID().uuidString).log")
        let store = LogStore(maxLines: maxLines, maxFileSizeBytes: 1_048_576, logURL: url)
        return (store, url)
    }

    private func appendLines(_ store: LogStore, count: Int, component: String = "Test") {
        for i in 0..<count {
            Log.info("line \(i)", component: component, store: store)
        }
    }

    // MARK: - Basic append / snapshot

    func testAppendAndSnapshot() {
        let (store, _) = makeTempStore()
        Log.info("hello", component: "Test", store: store)
        Log.debug("world", component: "Test", store: store)
        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[0].message, "hello")
        XCTAssertEqual(snap[1].message, "world")
    }

    // MARK: - Ring-buffer cap

    func testRingBufferDropsOldestWhenFull() {
        let cap = 50
        let (store, _) = makeTempStore(maxLines: cap)

        // Append cap + 10 lines — the first 10 should be dropped.
        for i in 0..<(cap + 10) {
            Log.info("line \(i)", component: "Test", store: store)
        }

        let snap = store.snapshot()
        XCTAssertEqual(snap.count, cap, "Buffer must stay at cap")
        // The first surviving line should be "line 10" (lines 0-9 were dropped).
        XCTAssertEqual(snap.first?.message, "line 10")
        XCTAssertEqual(snap.last?.message, "line \(cap + 9)")
    }

    func testRingBufferAtExactCap() {
        let cap = 10
        let (store, _) = makeTempStore(maxLines: cap)
        appendLines(store, count: cap)
        XCTAssertEqual(store.snapshot().count, cap)
    }

    // MARK: - Clear

    func testClearEmptiesBuffer() {
        let (store, _) = makeTempStore()
        appendLines(store, count: 20)
        XCTAssertFalse(store.snapshot().isEmpty)

        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testClearAllowsNewEntriesAfter() {
        let (store, _) = makeTempStore(maxLines: 5)
        appendLines(store, count: 5)
        store.clear()
        Log.warn("after clear", component: "Test", store: store)
        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].message, "after clear")
        XCTAssertEqual(snap[0].level, .warn)
    }

    // MARK: - copyPayload

    func testCopyPayloadContainsHeader() {
        let (store, _) = makeTempStore()
        Log.error("test error", component: "PayloadTest", store: store)
        let payload = store.copyPayload(appMode: "background")
        XCTAssertTrue(payload.contains("Vocateca Diagnostic Log"))
        XCTAssertTrue(payload.contains("macOS"))
        XCTAssertTrue(payload.contains("Mode:    background"))
        XCTAssertTrue(payload.contains("test error"))
    }

    func testCopyPayloadCountsLevels() {
        let (store, _) = makeTempStore()
        Log.info("a", component: "T", store: store)
        Log.info("b", component: "T", store: store)
        Log.error("c", component: "T", store: store)
        let payload = store.copyPayload()
        XCTAssertTrue(payload.contains("INFO=2"))
        XCTAssertTrue(payload.contains("ERROR=1"))
    }

    func testCopyPayloadEmptyStore() {
        let (store, _) = makeTempStore()
        let payload = store.copyPayload()
        XCTAssertTrue(payload.contains("Entries: 0"))
    }

    // MARK: - LogLine formatting

    func testLogLineFormattedContainsAllParts() {
        let (store, _) = makeTempStore()
        Log.warn("something broke", component: "Comp",
                 context: [("key", "val"), ("n", "42")],
                 store: store)
        let line = store.snapshot().first!
        let fmt = line.formatted
        XCTAssertTrue(fmt.contains("[WARN]"))
        XCTAssertTrue(fmt.contains("[Comp]"))
        XCTAssertTrue(fmt.contains("something broke"))
        XCTAssertTrue(fmt.contains("key=val"))
        XCTAssertTrue(fmt.contains("n=42"))
    }

    // MARK: - File sink

    func testFileIsCreatedOnInit() throws {
        let (_, url) = makeTempStore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Log file should be created on init")
    }

    func testLinesAreWrittenToFile() throws {
        let (store, url) = makeTempStore()
        Log.info("file-line", component: "FileTest", store: store)

        // Give the synchronous write a chance to complete (it's inside the lock, not async).
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("file-line"))
    }

    func testClearTruncatesFile() throws {
        let (store, url) = makeTempStore()
        appendLines(store, count: 10)
        store.clear()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.isEmpty, "File should be empty after clear")
    }

    // MARK: - L2: rotation to a .1 generation

    /// When the file exceeds the size cap it must rotate to a `.1` generation
    /// (retaining the just-rotated content) rather than truncating in place, AND
    /// the triggering entry must land in the fresh file — not be dropped.
    ///
    /// A generous cap + one write per phase gives EXACTLY one rotation, so the
    /// assertions are deterministic (a tiny cap would rotate repeatedly and the
    /// single retained `.1` would only hold the last pre-rotation batch).
    func testRotationCreatesDotOneGenerationAndKeepsTriggerEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logrotate-\(UUID().uuidString).log")
        let cap: Int64 = 4096
        let store = LogStore(maxLines: 10_000, maxFileSizeBytes: cap, logURL: url)

        // Phase 1: write a single line that on its own EXCEEDS the cap — a big
        // padded message — so the file is over-cap but has NOT rotated yet (the
        // size check runs on the NEXT write). This line is the marker we expect in
        // the .1 generation.
        let bigPad = String(repeating: "X", count: Int(cap) + 200)
        Log.info("PRE-ROTATION-marker \(bigPad)", component: "Rot", store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path),
                       "no rotation yet — the size check fires on the NEXT write")

        // Phase 2: the next write sees the over-cap file and rotates, then writes
        // this triggering entry into the FRESH file.
        Log.warn("TRIGGER-ENTRY-marker", component: "Rot", store: store)

        let rotatedURL = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path),
                      "a .1 generation must exist after rotation")

        // The rotated file holds the pre-rotation content.
        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        XCTAssertTrue(rotated.contains("PRE-ROTATION-marker"),
                      "the .1 generation must retain the pre-rotation content")

        // The current file contains the triggering entry (no longer dropped) and
        // NOT the old content (it's a fresh file).
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current.contains("TRIGGER-ENTRY-marker"),
                      "the triggering entry must land in the fresh current file, not be dropped")
        XCTAssertFalse(current.contains("PRE-ROTATION-marker"),
                       "the fresh current file must not still contain the rotated-away content")

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    /// Exactly ONE previous generation is kept: a second rotation replaces `.1`
    /// with the newer content (there is no `.2` / `.1.1`).
    func testRotationKeepsExactlyOneGeneration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logrotate2-\(UUID().uuidString).log")
        let cap: Int64 = 4096
        let store = LogStore(maxLines: 10_000, maxFileSizeBytes: cap, logURL: url)
        let bigPad = String(repeating: "Y", count: Int(cap) + 200)

        // Rotation 1: epochA over-cap line, then a small line triggers rotation.
        Log.info("epochA-marker \(bigPad)", component: "Rot", store: store)
        Log.info("small-1", component: "Rot", store: store)
        // Rotation 2: epochB over-cap line, then a small line triggers rotation 2
        // (must OVERWRITE .1 with the epochB batch).
        Log.info("epochB-marker \(bigPad)", component: "Rot", store: store)
        Log.info("small-2", component: "Rot", store: store)

        let rotatedURL = url.appendingPathExtension("1")
        let dotTwo = url.appendingPathExtension("1").appendingPathExtension("1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dotTwo.path),
                       "only one previous generation is kept — no .1.1 / .2")

        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        XCTAssertTrue(rotated.contains("epochB-marker"),
                      "the single .1 generation must hold the MOST RECENT rotated content")
        XCTAssertFalse(rotated.contains("epochA-marker"),
                       "the older epoch must have been discarded (only one generation kept)")

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - Thread safety (basic concurrent append)

    func testConcurrentAppendsDoNotCrash() async {
        let (store, _) = makeTempStore(maxLines: 200)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                let idx = i
                group.addTask {
                    Log.debug("concurrent \(idx)", component: "Concurrent", store: store)
                }
            }
        }
        // No assertion beyond "no crash" — just that the count is sane.
        XCTAssertLessThanOrEqual(store.snapshot().count, 200)
    }
}
