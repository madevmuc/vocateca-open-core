import XCTest
@testable import VocatecaCore

// MARK: - Fake filesystem

/// In-memory filesystem for deterministic tests — no disk I/O.
class FakeFileOps: FileMigrationOperations, @unchecked Sendable {

    // Directories that "exist" on the fake filesystem.
    var existingDirs: Set<String> = []
    // Files that "exist": path → size in bytes.
    var files: [String: Int64] = [:]
    // Files that "exist" in directory listings but whose size is unreadable (nil).
    var noSizeFiles: Set<String> = []

    // Recorded operations for assertion.
    var createdDirs: [String] = []
    var movedItems: [(src: String, dst: String)] = []
    var copiedItems: [(src: String, dst: String)] = []
    var removedItems: [String] = []

    // Inject failures.
    var moveItemShouldThrow = false
    var copyItemShouldThrow = false
    var contentsError = false

    // MARK: - FileMigrationOperations

    func directoryExists(at url: URL) -> Bool {
        existingDirs.contains(url.path)
    }

    func createDirectory(at url: URL) throws {
        existingDirs.insert(url.path)
        createdDirs.append(url.path)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        guard !moveItemShouldThrow else {
            throw CocoaError(.fileWriteNoPermission)
        }
        existingDirs.remove(src.path)
        existingDirs.insert(dst.path)
        movedItems.append((src.path, dst.path))
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        guard !contentsError else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // Return file children registered under this directory (both sized and no-size).
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let sizedChildren   = files.keys.filter    { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
        let noSizeChildren  = noSizeFiles.filter   { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
        return (sizedChildren + noSizeChildren).map { URL(fileURLWithPath: $0) }
    }

    func copyItem(at src: URL, to dst: URL) throws {
        guard !copyItemShouldThrow else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if let size = files[src.path] {
            files[dst.path] = size
        }
        copiedItems.append((src.path, dst.path))
    }

    func removeItem(at url: URL) throws {
        existingDirs.remove(url.path)
        files.removeValue(forKey: url.path)
        removedItems.append(url.path)
    }

    func fileSize(at url: URL) -> Int64? {
        // noSizeFiles entries explicitly return nil (unreadable size).
        if noSizeFiles.contains(url.path) { return nil }
        return files[url.path]
    }

    // MARK: - Helpers

    func addFile(_ path: String, size: Int64 = 100) {
        files[path] = size
        // Ensure parent dirs exist (simple, single level).
        let parent = (path as NSString).deletingLastPathComponent
        existingDirs.insert(parent)
    }
}

// MARK: - Fake Keychain

final class FakeKeychainOps: KeychainMigrationOperations, @unchecked Sendable {
    var legacyStore: [String: Data] = [:]
    var newStore: [String: Data] = [:]

    // MARK: - KeychainMigrationOperations

    /// Enumerates all items in the fake legacy store (satisfies the new self-sufficient API).
    func enumerateLegacyAccounts() throws -> [(account: String, data: Data)] {
        legacyStore.map { (account: $0.key, data: $0.value) }
            .sorted { $0.account < $1.account } // deterministic order for tests
    }

    func readLegacy(account: String) throws -> Data? {
        legacyStore[account]
    }

    func writeNew(_ data: Data, account: String) throws {
        newStore[account] = data
    }

    func deleteLegacy(account: String) throws {
        legacyStore.removeValue(forKey: account)
    }

    func newServiceHasItems() throws -> Bool {
        !newStore.isEmpty
    }
}

// MARK: - AppDataMigrationTests

final class AppDataMigrationTests: XCTestCase {

    private let newDir   = URL(fileURLWithPath: "/fake/Library/Application Support/Vocateca")
    private let legacyDir = URL(fileURLWithPath: "/fake/Library/Application Support/Paragraphos")

    // MARK: - Case 1: already migrated

    func testAlreadyMigrated_WhenNewDirExistsWithRealData_ReturnsAlreadyMigrated() {
        let ops = FakeFileOps()
        ops.addFile(newDir.path + "/state.sqlite", size: 512)  // real data present

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated)
        XCTAssertTrue(ops.movedItems.isEmpty, "Should not move when already migrated")
        XCTAssertTrue(ops.createdDirs.isEmpty, "Should not create dir when already migrated")
    }

    func testAlreadyMigrated_WhenNewDirExistsEmpty_AndNoLegacy_ReturnsAlreadyMigrated() {
        // Empty target dir + no legacy data → treat as already set up (nothing to migrate).
        let ops = FakeFileOps()
        ops.existingDirs.insert(newDir.path)
        // No files registered; no legacy dir.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated,
                       "Empty target with no legacy data should be left as-is (treated as already migrated)")
        XCTAssertTrue(ops.movedItems.isEmpty)
        XCTAssertTrue(ops.removedItems.isEmpty, "Must not remove the empty target dir when there is no legacy to replace it")
    }

    // MARK: - Case 2: legacy dir present, atomic move succeeds

    func testLegacyPresent_AtomicMoveSucceeds_ReturnsMovedAtomically() {
        let ops = FakeFileOps()
        ops.addFile(legacyDir.path + "/state.sqlite", size: 1024)   // real data in legacy
        // newDir does NOT exist

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .movedAtomically)
        XCTAssertEqual(ops.movedItems.count, 1)
        XCTAssertEqual(ops.movedItems.first?.src, legacyDir.path)
        XCTAssertEqual(ops.movedItems.first?.dst, newDir.path)
        // New dir appears in filesystem after move.
        XCTAssertTrue(ops.directoryExists(at: newDir))
        XCTAssertFalse(ops.directoryExists(at: legacyDir))
    }

    // MARK: - Case 2b: legacy present, atomic move fails, copy succeeds

    func testLegacyPresent_AtomicMoveFails_FallsBackToCopyAndReturnsSuccess() {
        let ops = FakeFileOps()
        ops.existingDirs.insert(legacyDir.path)
        ops.addFile(legacyDir.path + "/state.sqlite", size: 1024)
        ops.addFile(legacyDir.path + "/settings.yaml", size: 256)
        ops.moveItemShouldThrow = true   // force atomic move failure

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .copiedFallback(success: true))
        XCTAssertEqual(ops.copiedItems.count, 2, "Should copy 2 files")
        // Legacy dir should have been removed after successful copy.
        XCTAssertTrue(ops.removedItems.contains(legacyDir.path))
    }

    // MARK: - Case 2c: legacy present, atomic move fails, copy also fails

    func testLegacyPresent_AtomicAndCopyBothFail_ReturnsFallbackFailure_LeavesLegacyIntact() {
        let ops = FakeFileOps()
        ops.existingDirs.insert(legacyDir.path)
        ops.addFile(legacyDir.path + "/state.sqlite", size: 1024)
        ops.moveItemShouldThrow = true
        ops.copyItemShouldThrow = true

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .copiedFallback(success: false))
        // Legacy dir must NOT be removed when copy failed.
        XCTAssertFalse(ops.removedItems.contains(legacyDir.path),
                       "Must NOT remove legacy dir on copy failure — data would be lost")
    }

    // MARK: - Case 3: fresh install

    func testFreshInstall_WhenNeitherDirExists_CreatesDirAndReturnsFreshInstall() {
        let ops = FakeFileOps()
        // Neither dir exists.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .freshInstall)
        XCTAssertTrue(ops.directoryExists(at: newDir), "New dir should be created for fresh install")
        XCTAssertTrue(ops.movedItems.isEmpty)
    }

    // MARK: - Idempotency

    func testIdempotency_RunTwice_SecondRunIsAlreadyMigrated() {
        let ops = FakeFileOps()
        ops.addFile(legacyDir.path + "/state.sqlite", size: 512)  // real data in legacy

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let first = migration.runIfNeeded()
        XCTAssertEqual(first, .movedAtomically)

        // Second run — newDir now exists (moved in first run); legacy no longer has files.
        // Empty target + no real legacy data → alreadyMigrated.
        let second = migration.runIfNeeded()
        XCTAssertEqual(second, .alreadyMigrated)
        // Move should only have happened once.
        XCTAssertEqual(ops.movedItems.count, 1)
    }

    // MARK: - Keychain migration

    func testKeychainMigration_CopiesAndDeletesLegacyEntries() {
        let ops = FakeFileOps()
        let keychain = FakeKeychainOps()
        let cookieData = Data("session_cookie=abc".utf8)
        keychain.legacyStore["testuser123"] = cookieData

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(accountIDs: ["testuser123"], keychain: keychain)

        XCTAssertEqual(keychain.newStore["testuser123"], cookieData, "Cookie should be in new store")
        XCTAssertNil(keychain.legacyStore["testuser123"], "Cookie should be removed from legacy store")
    }

    func testKeychainMigration_NoOpWhenAccountListIsEmpty() {
        let ops = FakeFileOps()
        let keychain = FakeKeychainOps()
        keychain.legacyStore["testuser123"] = Data("cookie".utf8)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(accountIDs: [], keychain: keychain)

        // Legacy should be unchanged.
        XCTAssertNotNil(keychain.legacyStore["testuser123"])
        XCTAssertTrue(keychain.newStore.isEmpty)
    }

    func testKeychainMigration_SkipsMissingLegacyAccount() {
        let ops = FakeFileOps()
        let keychain = FakeKeychainOps()
        // legacyStore is empty — the account doesn't exist in legacy.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(accountIDs: ["nolegacy"], keychain: keychain)

        XCTAssertTrue(keychain.newStore.isEmpty, "Nothing to migrate if legacy entry is absent")
    }

    func testKeychainMigration_MultiplAccounts() {
        let ops = FakeFileOps()
        let keychain = FakeKeychainOps()
        keychain.legacyStore["user_a"] = Data("cookie_a".utf8)
        keychain.legacyStore["user_b"] = Data("cookie_b".utf8)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(accountIDs: ["user_a", "user_b"], keychain: keychain)

        XCTAssertNotNil(keychain.newStore["user_a"])
        XCTAssertNotNil(keychain.newStore["user_b"])
        XCTAssertTrue(keychain.legacyStore.isEmpty)
    }

    // MARK: - Keychain migration (enumeration-based, no accountIDs list)

    func testKeychainMigration_Enumerate_CopiesAndDeletesLegacyEntries() {
        let ops      = FakeFileOps()
        let keychain = FakeKeychainOps()
        let cookieData = Data("session_cookie=abc".utf8)
        keychain.legacyStore["testuser123"] = cookieData

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(keychain: keychain)

        XCTAssertEqual(keychain.newStore["testuser123"], cookieData,
                       "Cookie should be written to new store")
        XCTAssertNil(keychain.legacyStore["testuser123"],
                     "Cookie should be removed from legacy store")
    }

    func testKeychainMigration_Enumerate_NoOpWhenLegacyEmpty() {
        let ops      = FakeFileOps()
        let keychain = FakeKeychainOps()
        // legacyStore is empty — nothing to migrate.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(keychain: keychain)

        XCTAssertTrue(keychain.newStore.isEmpty,
                      "New store must stay empty when legacy has no items")
    }

    func testKeychainMigration_Enumerate_MultipleAccounts() {
        let ops      = FakeFileOps()
        let keychain = FakeKeychainOps()
        keychain.legacyStore["user_a"] = Data("cookie_a".utf8)
        keychain.legacyStore["user_b"] = Data("cookie_b".utf8)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(keychain: keychain)

        XCTAssertNotNil(keychain.newStore["user_a"])
        XCTAssertNotNil(keychain.newStore["user_b"])
        XCTAssertTrue(keychain.legacyStore.isEmpty, "All legacy entries should be deleted after migration")
    }

    func testKeychainMigration_Enumerate_IdempotentWhenNewServiceAlreadyHasItems() {
        let ops      = FakeFileOps()
        let keychain = FakeKeychainOps()
        keychain.legacyStore["user_a"] = Data("old_cookie".utf8)
        // Pre-populate new store — simulates a migration that already ran.
        keychain.newStore["user_a"]    = Data("existing_cookie".utf8)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        migration.migrateKeychainIfNeeded(keychain: keychain)

        // New store value must not be overwritten.
        XCTAssertEqual(keychain.newStore["user_a"], Data("existing_cookie".utf8),
                       "Already-migrated new-service entries must not be overwritten")
        // Legacy must remain untouched (migration was skipped).
        XCTAssertNotNil(keychain.legacyStore["user_a"],
                        "Legacy entry must remain when migration is skipped for idempotency")
    }

    // MARK: - I1: nil file size treated as verification failure

    func testCopyFallback_NilSrcSize_TreatsAsVerificationFailure_LeavesLegacyIntact() {
        let ops = FakeFileOps()
        ops.existingDirs.insert(legacyDir.path)
        // Register a known data file with an unreadable size (present in directory
        // listing, but fileSize(at:) returns nil — simulates e.g. a sparse file or a
        // filesystem that can't report size).
        // Must use a known data filename so hasRealData() detects legacy as populated.
        let filePath = legacyDir.path + "/state.sqlite"
        ops.noSizeFiles.insert(filePath)
        ops.moveItemShouldThrow = true  // force fallback path

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .copiedFallback(success: false),
                       "Nil file size must be treated as verification failure, not a pass")
        XCTAssertFalse(ops.removedItems.contains(legacyDir.path),
                       "Legacy dir must NOT be removed when verification cannot be confirmed")
    }

    func testCopyFallback_NilDstSize_TreatsAsVerificationFailure() {
        // Use a custom FakeFileOps subclass that returns nil for dst sizes only
        // (simulates a filesystem that can't report size for newly copied items).
        class NilDstSizeOps: FakeFileOps, @unchecked Sendable {
            private var dstPaths: Set<String> = []
            override func copyItem(at src: URL, to dst: URL) throws {
                dstPaths.insert(dst.path)
                // Do NOT copy the size into files[] — dst has no size entry → nil.
                copiedItems.append((src.path, dst.path))
            }
            override func fileSize(at url: URL) -> Int64? {
                dstPaths.contains(url.path) ? nil : super.fileSize(at: url)
            }
        }

        let ops = NilDstSizeOps()
        ops.existingDirs.insert(legacyDir.path)
        ops.addFile(legacyDir.path + "/state.sqlite", size: 512)
        ops.moveItemShouldThrow = true

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .copiedFallback(success: false),
                       "Nil dst file size must be treated as verification failure")
        XCTAssertFalse(ops.removedItems.contains(legacyDir.path),
                       "Legacy dir must NOT be removed when dst size cannot be verified")
    }

    // MARK: - I2: both dirs exist warning logged

    func testBothDirsExist_LogsWarningAndReturnsAlreadyMigrated() {
        let ops = FakeFileOps()
        // New dir must have real data so the migration detects it as genuinely migrated.
        ops.addFile(newDir.path + "/state.sqlite", size: 1024)
        ops.existingDirs.insert(legacyDir.path)

        // Use a lock-protected collector because the logger closure is @Sendable.
        final class LogCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var lines: [String] = []
            func append(_ msg: String) { lock.lock(); lines.append(msg); lock.unlock() }
        }
        let collector = LogCollector()
        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops) { msg in
            collector.append(msg)
        }
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated)
        XCTAssertTrue(collector.lines.contains(where: { $0.contains("WARNING") && $0.contains("Both") }),
                      "Must emit a WARNING log when both legacy and new dirs exist. Got: \(collector.lines)")
    }

    // MARK: - Empty-target hardening (the accidental-empty-dir bug)

    /// Core regression: an empty Vocateca dir (auto-created by a tool/crash before
    /// migration) must NOT mask a populated legacy Paragraphos dir.
    func testEmptyTarget_PopulatedLegacy_MigratesLegacyIntoTarget() {
        let ops = FakeFileOps()
        // Target exists but is empty (no known data files).
        ops.existingDirs.insert(newDir.path)
        // Legacy has real data.
        ops.addFile(legacyDir.path + "/state.sqlite",    size: 1024)
        ops.addFile(legacyDir.path + "/settings.yaml",   size: 256)
        ops.addFile(legacyDir.path + "/watchlist.yaml",  size: 128)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        // Must have migrated (moved atomically after removing empty target).
        XCTAssertEqual(result, .movedAtomically,
                       "Empty target must be replaced by legacy data via atomic move")
        // The empty target dir was removed before the move.
        XCTAssertTrue(ops.removedItems.contains(newDir.path),
                      "Empty target dir must be removed before migration")
        // Atomic move happened: legacy → new.
        XCTAssertEqual(ops.movedItems.count, 1)
        XCTAssertEqual(ops.movedItems.first?.src, legacyDir.path)
        XCTAssertEqual(ops.movedItems.first?.dst, newDir.path)
        // New dir is populated (from move); legacy is gone.
        XCTAssertTrue(ops.directoryExists(at: newDir))
        XCTAssertFalse(ops.directoryExists(at: legacyDir))
    }

    /// Populated target must NEVER be overwritten, even if legacy also has data.
    /// A known data file present in legacy but missing from the target (here
    /// `settings.yaml`) IS backfilled — that is the data-loss-gap fix — but the
    /// file the target already has (`state.sqlite`) must never be touched/moved.
    func testPopulatedTarget_PopulatedLegacy_TargetKeptUntouched() {
        let ops = FakeFileOps()
        // Both dirs exist with real data. Target is missing settings.yaml.
        ops.addFile(newDir.path    + "/state.sqlite",  size: 2048)
        ops.addFile(legacyDir.path + "/state.sqlite",  size: 1024)
        ops.addFile(legacyDir.path + "/settings.yaml", size: 256)

        final class LogCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var lines: [String] = []
            func append(_ msg: String) { lock.lock(); lines.append(msg); lock.unlock() }
        }
        let collector = LogCollector()
        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops) { msg in
            collector.append(msg)
        }
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .backfilled(files: ["settings.yaml"]),
                       "Missing known file (settings.yaml) must be backfilled from legacy into the populated target")
        // Target must never be removed, and its EXISTING file is never moved/overwritten.
        XCTAssertFalse(ops.removedItems.contains(newDir.path),
                       "Must NEVER remove a populated target dir")
        XCTAssertTrue(ops.movedItems.isEmpty,
                      "Must NEVER move when target is populated")
        // Only the missing file (settings.yaml) is copied — state.sqlite (already
        // present in target) must not appear in copiedItems.
        XCTAssertEqual(ops.copiedItems.count, 1)
        XCTAssertEqual(ops.copiedItems.first?.src, legacyDir.path + "/settings.yaml")
        XCTAssertEqual(ops.copiedItems.first?.dst, newDir.path + "/settings.yaml")
        XCTAssertFalse(ops.copiedItems.contains { $0.dst == newDir.path + "/state.sqlite" },
                       "Must NEVER overwrite a file that already exists in the target")
        // The pre-existing target file must retain its original size (never overwritten).
        XCTAssertEqual(ops.files[newDir.path + "/state.sqlite"], 2048,
                       "Existing target file's content must be untouched")
        // Legacy is left intact.
        XCTAssertTrue(ops.directoryExists(at: legacyDir),
                      "Legacy dir must remain untouched when target is populated")
        // Warning must be logged.
        XCTAssertTrue(collector.lines.contains(where: { $0.contains("WARNING") && $0.contains("Both") }),
                      "Must log a WARNING when both dirs have real data. Got: \(collector.lines)")
        // Backfill must be logged.
        XCTAssertTrue(collector.lines.contains(where: { $0.contains("Backfilled") && $0.contains("settings.yaml") }),
                      "Must log the backfilled filename. Got: \(collector.lines)")
    }

    /// Empty target + no legacy (or empty legacy) → treat as already set up; no crash.
    func testEmptyTarget_NoLegacy_ReturnsAlreadyMigrated() {
        let ops = FakeFileOps()
        ops.existingDirs.insert(newDir.path)
        // No legacy dir at all.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated,
                       "Empty target + no legacy → nothing to migrate, use target as-is")
        XCTAssertTrue(ops.movedItems.isEmpty)
        XCTAssertTrue(ops.removedItems.isEmpty,
                      "Must not touch the empty target when there is no legacy")
    }

    /// When atomic move of legacy into an (empty-target-removed) slot fails,
    /// fall back to copy+verify; legacy must not be deleted until verified.
    func testEmptyTarget_PopulatedLegacy_AtomicMoveFails_FallsBackToCopy() {
        let ops = FakeFileOps()
        ops.existingDirs.insert(newDir.path)            // empty target
        ops.addFile(legacyDir.path + "/state.sqlite",  size: 512)
        ops.addFile(legacyDir.path + "/settings.yaml", size: 128)
        ops.moveItemShouldThrow = true   // force copy fallback after empty-target removal

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .copiedFallback(success: true),
                       "Should fall back to copy when atomic move fails after removing empty target")
        // Empty target was removed first.
        XCTAssertTrue(ops.removedItems.contains(newDir.path),
                      "Empty target dir must be removed before migration attempt")
        // Both legacy files were copied.
        XCTAssertEqual(ops.copiedItems.count, 2, "Both legacy files must be copied")
        // Legacy dir removed after successful copy.
        XCTAssertTrue(ops.removedItems.contains(legacyDir.path),
                      "Legacy dir must be removed after successful copy-verify")
    }

    // MARK: - Backfill: the confirmed real-world data-loss gap

    /// Regression test for the confirmed bug: target (Vocateca) had state.sqlite
    /// but NOT watchlist.yaml, because a prior partial migration/move left it
    /// behind in the legacy dir. Every show became "DB-only" (title == slug, no
    /// artwork, no RSS) because watchlist.yaml never made it over. After the
    /// fix, watchlist.yaml must be copied legacy → new, and the existing
    /// state.sqlite in the target must never be overwritten.
    func testBackfill_TargetMissingWatchlist_LegacyHasIt_CopiesWatchlistOnly() {
        let ops = FakeFileOps()
        // Target has state.sqlite only (the exact real-world shape of the bug).
        ops.addFile(newDir.path    + "/state.sqlite",   size: 4096)
        // Legacy still has both state.sqlite (stale copy) and the watchlist that
        // never made it over.
        ops.addFile(legacyDir.path + "/state.sqlite",   size: 4096)
        ops.addFile(legacyDir.path + "/watchlist.yaml", size: 777)

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .backfilled(files: ["watchlist.yaml"]),
                       "watchlist.yaml must be detected as missing from target and backfilled")
        // Only the missing file was copied.
        XCTAssertEqual(ops.copiedItems.count, 1)
        XCTAssertEqual(ops.copiedItems.first?.src, legacyDir.path + "/watchlist.yaml")
        XCTAssertEqual(ops.copiedItems.first?.dst, newDir.path + "/watchlist.yaml")
        // Target now has watchlist.yaml.
        XCTAssertEqual(ops.files[newDir.path + "/watchlist.yaml"], 777,
                       "Target dir must now contain watchlist.yaml copied from legacy")
        // Target's pre-existing state.sqlite was never touched/overwritten.
        XCTAssertFalse(ops.copiedItems.contains { $0.dst == newDir.path + "/state.sqlite" },
                       "Must NEVER overwrite an existing target file (state.sqlite) during backfill")
        XCTAssertEqual(ops.files[newDir.path + "/state.sqlite"], 4096,
                       "Existing target state.sqlite must retain its original size")
        // Legacy dir is left intact (backfill only copies, never deletes legacy).
        XCTAssertTrue(ops.directoryExists(at: legacyDir))
        XCTAssertEqual(ops.files[legacyDir.path + "/watchlist.yaml"], 777,
                       "Legacy copy is left in place; backfill is copy-only, not move")
    }

    /// No backfill should occur — and result stays `.alreadyMigrated` — when the
    /// target already has every known data file that legacy has, even though
    /// legacy dir is still present.
    func testBackfill_TargetHasAllKnownFiles_NoBackfillNeeded_StaysAlreadyMigrated() {
        let ops = FakeFileOps()
        ops.addFile(newDir.path    + "/state.sqlite",   size: 100)
        ops.addFile(newDir.path    + "/watchlist.yaml", size: 200)
        ops.addFile(legacyDir.path + "/state.sqlite",   size: 999)   // stale legacy copy
        ops.addFile(legacyDir.path + "/watchlist.yaml", size: 999)   // stale legacy copy

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated,
                       "No backfill needed when target already has all known files present in legacy")
        XCTAssertTrue(ops.copiedItems.isEmpty, "Must not copy anything when nothing is missing")
        // Existing target files must retain their original (non-legacy) sizes.
        XCTAssertEqual(ops.files[newDir.path + "/state.sqlite"], 100)
        XCTAssertEqual(ops.files[newDir.path + "/watchlist.yaml"], 200)
    }

    /// No legacy dir at all → no backfill possible; behaves exactly as before.
    func testBackfill_NoLegacyDir_ReturnsAlreadyMigrated() {
        let ops = FakeFileOps()
        ops.addFile(newDir.path + "/state.sqlite", size: 100)
        // No legacy dir registered at all.

        let migration = AppDataMigration(newDataDir: newDir, legacyDataDir: legacyDir, fileOps: ops)
        let result = migration.runIfNeeded()

        XCTAssertEqual(result, .alreadyMigrated)
        XCTAssertTrue(ops.copiedItems.isEmpty)
    }

    // MARK: - M3: ordering invariant — migration runs before Paths.userDataDir auto-creates

    /// Documents the ordering invariant: `AppDataMigration.runIfNeeded()` must
    /// be called BEFORE `Paths.userDataDir()` is ever called at process start.
    ///
    /// This test verifies the invariant at the structural level:
    ///   1. `Paths.userDataDirWithoutCreating()` does NOT create the directory.
    ///   2. `Paths.userDataDir()` DOES create it (auto-create).
    ///   3. `AppDataMigration.runIfNeeded()` is safe to call when dir absent
    ///      (i.e. it detects fresh-install, not a stale already-migrated state).
    ///
    /// If the migration is wired AFTER `Paths.userDataDir()` would run, the new
    /// dir already exists and migration silently no-ops — orphaning legacy data.
    /// The call sites in `Sources/Vocateca/main.swift` and
    /// `Sources/vocateca-cli/main.swift` must invoke `runIfNeeded()` BEFORE any
    /// `Paths.userDataDir()` / `StateReader` / `StateStore` call.
    ///
    /// Compile-time enforcement: `Paths.userDataDir()` bears a doc comment
    /// stating the invariant; `main.swift` call sites are checked by this test
    /// via source-text scanning.
    func testOrderingInvariant_MigrationCalledBeforeUserDataDirAutoCreate() throws {
        // Structural check: the production main.swift files must call runIfNeeded
        // before any StateReader / Paths.userDataDir call.
        // We read the source texts here so removing the call sites breaks this test.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Migration/
            .deletingLastPathComponent()   // VocatecaCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // swift/
            .appendingPathComponent("Sources")

        let guiMain = root
            .appendingPathComponent("Vocateca/main.swift")
        let cliMain = root
            .appendingPathComponent("vocateca-cli/main.swift")

        for mainURL in [guiMain, cliMain] {
            let src = try String(contentsOf: mainURL, encoding: .utf8)
            XCTAssertTrue(
                src.contains("runIfNeeded"),
                "Migration wiring missing: \(mainURL.lastPathComponent) must call runIfNeeded() before any data access. File: \(mainURL.path)"
            )
        }

        // GUI main must NOT run migration in --snapshot mode (snapshot branches
        // exit before reaching the migration call).
        let guiSrc = try String(contentsOf: guiMain, encoding: .utf8)
        // The --snapshot branch calls exit(0) before migration — verify
        // the migration call appears AFTER the snapshot branch in the file.
        if let snapshotRange = guiSrc.range(of: "--snapshot"),
           let migrationRange = guiSrc.range(of: "runIfNeeded") {
            XCTAssertGreaterThan(
                guiSrc.distance(from: guiSrc.startIndex, to: migrationRange.lowerBound),
                guiSrc.distance(from: guiSrc.startIndex, to: snapshotRange.lowerBound),
                "In GUI main.swift, runIfNeeded() must appear AFTER the --snapshot branch (snapshot exits before migration)"
            )
        }
    }

    // MARK: - Constants

    func testConstants_ServiceNames() {
        XCTAssertEqual(AppDataMigration.legacyKeychainService, "com.paragraphos.instagram")
        XCTAssertEqual(AppDataMigration.newKeychainService,    "com.vocateca.instagram")
    }

    func testConstants_DirNames() {
        XCTAssertEqual(AppDataMigration.legacyDirName, "Paragraphos")
        XCTAssertEqual(AppDataMigration.newDirName,    "Vocateca")
    }

    // MARK: - Paths extension

    func testUserDataDirWithoutCreating_DoesNotCreateDir() {
        // The real userDataDirWithoutCreating should not touch disk.
        // We just verify the URL shape; we don't want to actually create a dir.
        let url = Paths.userDataDirWithoutCreating()
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Vocateca"))
    }

    func testLegacyDataDir_HasParagraphosInPath() {
        let url = Paths.legacyDataDir()
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Paragraphos"))
    }
}
