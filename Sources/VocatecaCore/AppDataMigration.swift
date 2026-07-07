import Foundation

// MARK: - Protocols (for testability)

/// Abstraction over the filesystem operations needed for the data migration.
/// The production implementation delegates to `FileManager`; tests use a fake.
public protocol FileMigrationOperations: Sendable {
    /// Returns `true` when `url` exists as a directory.
    func directoryExists(at url: URL) -> Bool
    /// Creates a directory (including intermediates) at `url`.
    func createDirectory(at url: URL) throws
    /// Moves `src` to `dst` atomically. Fails if `dst` already exists.
    func moveItem(at src: URL, to dst: URL) throws
    /// Lists the immediate children of `url`.
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// Copies a single file from `src` to `dst`. Does NOT copy directories.
    func copyItem(at src: URL, to dst: URL) throws
    /// Removes the item at `url`.
    func removeItem(at url: URL) throws
    /// Returns the file size in bytes, or nil if unknown.
    func fileSize(at url: URL) -> Int64?
}

/// Abstraction over Keychain operations for the credential migration.
/// The production implementation uses `SystemKeychainStore`; tests use a fake.
public protocol KeychainMigrationOperations: Sendable {
    /// Enumerates all account identifiers stored under the legacy service
    /// `com.paragraphos.instagram`.  Returns an empty array if there are none.
    func enumerateLegacyAccounts() throws -> [(account: String, data: Data)]
    /// Reads an entry from the old service name (com.paragraphos.instagram).
    func readLegacy(account: String) throws -> Data?
    /// Writes an entry to the new service name (com.vocateca.instagram).
    func writeNew(_ data: Data, account: String) throws
    /// Deletes from the old service name (com.paragraphos.instagram).
    func deleteLegacy(account: String) throws
    /// Returns true when the new service already contains at least one item.
    /// Used for idempotency: if new service is populated, skip re-migration.
    func newServiceHasItems() throws -> Bool
}

// MARK: - Migration result

/// Describes what the migration did (for logging and tests).
public enum MigrationResult: Equatable, Sendable {
    /// The new Vocateca dir already existed — nothing to do.
    case alreadyMigrated
    /// No legacy Paragraphos dir was found — fresh install path.
    case freshInstall
    /// Legacy dir was moved atomically to the new location.
    case movedAtomically
    /// Atomic move failed; fell back to copy-then-delete. `success` is false if
    /// any file failed to copy.
    case copiedFallback(success: Bool)
    /// The new Vocateca dir already had real data, but was missing one or more
    /// `knownDataFiles` that were present in the legacy dir (e.g. `state.sqlite`
    /// carried over but `watchlist.yaml` did not). Those specific files were
    /// copied from legacy → new to fill the gap; existing new-dir files were
    /// never touched. `files` lists the backfilled filenames.
    case backfilled(files: [String])
}

// MARK: - AppDataMigration

/// One-time, idempotent migration that runs at app startup **before** any
/// database or Keychain access.
///
/// Logic:
/// 1. New `Vocateca` dir exists **and has real data** → done (`alreadyMigrated`,
///    or `backfilled` — see below).
///    "Real data" means the dir contains at least one of the known data files:
///    `state.sqlite`, `settings.yaml`, or `watchlist.yaml`.
///    An empty dir (or one containing only `.DS_Store`/junk) is **not** real data
///    and does NOT count as already migrated — it may have been auto-created
///    accidentally before migration ran.
///    Before returning, if a legacy dir is also present, each of the
///    `knownDataFiles` that exists in the legacy dir but is MISSING from the
///    new dir is copied over (never overwriting a file already present in the
///    new dir). This closes a real data-loss gap: a partial migration could
///    leave `state.sqlite` in the new dir but drop `watchlist.yaml`, silently
///    orphaning show metadata. See `backfilled(files:)`.
/// 2. Legacy `Paragraphos` dir exists and has real data → migrate it:
///    a. If target does NOT exist → atomic move (existing path).
///    b. If target exists but is empty/junk → remove empty target, then atomic move;
///       on move failure, copy + verify each file, only delete legacy once verified.
/// 3. Otherwise (no real legacy data, target empty or absent) → `alreadyMigrated`
///    if target exists (nothing to migrate), or `freshInstall` if neither exists.
///
/// **Thread safety:** designed for single-threaded call from `@main` / `.task`.
/// All state is passed in via dependencies; no shared mutable state.
///
/// **Keychain migration:** reads legacy Instagram cookies (service
/// `com.paragraphos.instagram`) and re-writes under `com.vocateca.instagram`,
/// then deletes the old entry.  No-op if the old entry doesn't exist.
public struct AppDataMigration: Sendable {

    // MARK: - Constants

    /// The legacy data directory name (Paragraphos v1 / pre-rename).
    public static let legacyDirName = "Paragraphos"
    /// The new canonical data directory name.
    public static let newDirName = "Vocateca"
    /// Old Keychain service name.
    public static let legacyKeychainService = "com.paragraphos.instagram"
    /// New Keychain service name.
    public static let newKeychainService = "com.vocateca.instagram"

    /// Known data files that indicate a data directory is populated with real content.
    /// An app-data dir that contains at least one of these is considered non-empty.
    static let knownDataFiles: Set<String> = ["state.sqlite", "settings.yaml", "watchlist.yaml"]

    // MARK: - Dependencies

    private let newDataDir: URL
    private let legacyDataDir: URL
    private let fileOps: FileMigrationOperations
    private let logger: @Sendable (String) -> Void

    // MARK: - Init

    /// Production initialiser — uses real filesystem + Paths.
    public init(
        newDataDir: URL = Paths.userDataDirWithoutCreating(),
        legacyDataDir: URL = Paths.legacyDataDir(),
        logger: @escaping @Sendable (String) -> Void = { msg in
            Log.info(msg, component: "Migration")
        }
    ) {
        self.newDataDir = newDataDir
        self.legacyDataDir = legacyDataDir
        self.fileOps = RealFileMigrationOperations()
        self.logger = logger
    }

    /// Testable initialiser — inject fake filesystem + logger.
    public init(
        newDataDir: URL,
        legacyDataDir: URL,
        fileOps: FileMigrationOperations,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.newDataDir = newDataDir
        self.legacyDataDir = legacyDataDir
        self.fileOps = fileOps
        self.logger = logger
    }

    // MARK: - Run

    /// Performs the migration. Safe to call on every launch (idempotent).
    ///
    /// - Returns: `MigrationResult` describing what happened.
    @discardableResult
    public func runIfNeeded() -> MigrationResult {
        let newDirExists    = fileOps.directoryExists(at: newDataDir)
        let legacyDirExists = fileOps.directoryExists(at: legacyDataDir)

        let newHasRealData    = newDirExists    && hasRealData(in: newDataDir)
        let legacyHasRealData = legacyDirExists && hasRealData(in: legacyDataDir)

        // Case 1: target has real data — it is genuinely migrated/in-use; never overwrite.
        if newHasRealData {
            if legacyDirExists {
                // I2: warn if legacy dir is also present (unexpected; may hold stale data).
                logger("WARNING: Both legacy dir (\(legacyDataDir.path)) and new dir (\(newDataDir.path)) exist. " +
                       "New dir has real data — legacy dir left untouched; manual inspection may be needed.")

                // Backfill guard: the new dir has SOME real data, but a prior partial
                // migration may have dropped one or more known data files (e.g.
                // state.sqlite carried over but watchlist.yaml did not — the
                // confirmed real-world bug). Fill only genuine gaps; never
                // overwrite a file that already exists in the new dir.
                let backfilledFiles = backfillMissingKnownFiles()
                if !backfilledFiles.isEmpty {
                    return .backfilled(files: backfilledFiles)
                }
            } else {
                logger("Vocateca data dir already present with real data at \(newDataDir.path) — no migration needed.")
            }
            return .alreadyMigrated
        }

        // Case 2: legacy has real data — migrate it into the target location.
        if legacyHasRealData {
            if newDirExists {
                // Target exists but is empty/junk. Remove it first so atomic move can succeed.
                logger("Empty/junk target dir found at \(newDataDir.path) — removing it to replace with legacy data from \(legacyDataDir.path).")
                do {
                    try fileOps.removeItem(at: newDataDir)
                } catch {
                    logger("Could not remove empty target dir (\(error)); will attempt copy fallback instead.")
                    // removeItem failed; fall through to migrateFromLegacy which will
                    // try atomic move (will likely fail too) and then copy fallback.
                    return migrateFromLegacy()
                }
            } else {
                logger("Legacy data dir found at \(legacyDataDir.path) — migrating to \(newDataDir.path).")
            }
            return migrateFromLegacy()
        }

        // Case 3: no real data in either location.
        if newDirExists {
            // Target dir exists but is empty/junk and there is no legacy to migrate.
            // Nothing to do — app will use it as-is for a fresh start.
            logger("Vocateca data dir exists (empty/no real data) at \(newDataDir.path) and no legacy data found — treating as fresh install.")
            return .alreadyMigrated
        }

        // Neither dir exists — true fresh install.
        logger("No existing data dir found — creating fresh \(newDataDir.path).")
        do {
            try fileOps.createDirectory(at: newDataDir)
            return .freshInstall
        } catch {
            logger("Failed to create new data dir: \(error)")
            return .freshInstall
        }
    }

    // MARK: - Private helpers

    /// Returns `true` when `dir` contains at least one of the known data files
    /// (`state.sqlite`, `settings.yaml`, `watchlist.yaml`) as an immediate child.
    ///
    /// A directory that exists but holds only `.DS_Store`, junk, or nothing at all
    /// is considered empty and returns `false`.  This guards against an accidentally
    /// auto-created empty Vocateca dir masking a populated legacy Paragraphos dir.
    private func hasRealData(in dir: URL) -> Bool {
        guard let children = try? fileOps.contentsOfDirectory(at: dir) else {
            return false
        }
        return children.contains { child in
            AppDataMigration.knownDataFiles.contains(child.lastPathComponent)
        }
    }

    /// Returns the set of `knownDataFiles` filenames present as immediate
    /// children of `dir`. Used to diff legacy vs. new dir contents so we only
    /// backfill genuine gaps.
    private func knownFileNames(in dir: URL) -> Set<String> {
        guard let children = try? fileOps.contentsOfDirectory(at: dir) else {
            return []
        }
        var names = Set<String>()
        for child in children {
            let name = child.lastPathComponent
            if AppDataMigration.knownDataFiles.contains(name) {
                names.insert(name)
            }
        }
        return names
    }

    /// For each file in `knownDataFiles` that exists in the legacy dir but is
    /// missing from the new dir, copies it legacy → new. Never overwrites a
    /// file that already exists in the new dir — only fills genuine gaps left
    /// by a partial/older migration.
    ///
    /// - Returns: the filenames that were successfully backfilled (empty if
    ///   there was nothing to do, or the legacy dir doesn't exist).
    private func backfillMissingKnownFiles() -> [String] {
        let legacyNames = knownFileNames(in: legacyDataDir)
        guard !legacyNames.isEmpty else { return [] }

        let newNames = knownFileNames(in: newDataDir)
        let missing = legacyNames.subtracting(newNames).sorted()
        guard !missing.isEmpty else { return [] }

        var backfilled: [String] = []
        for name in missing {
            let src = legacyDataDir.appendingPathComponent(name)
            let dst = newDataDir.appendingPathComponent(name)
            do {
                try fileOps.copyItem(at: src, to: dst)
                logger("Backfilled missing data file into Vocateca dir: \(name) (copied from legacy \(legacyDataDir.path) — did not exist in \(newDataDir.path)).")
                backfilled.append(name)
            } catch {
                logger("Failed to backfill missing data file '\(name)' from legacy dir: \(error)")
            }
        }
        return backfilled
    }

    private func migrateFromLegacy() -> MigrationResult {
        // Try atomic move first.
        do {
            try fileOps.moveItem(at: legacyDataDir, to: newDataDir)
            logger("Atomic move succeeded: \(legacyDataDir.path) → \(newDataDir.path)")
            return .movedAtomically
        } catch {
            logger("Atomic move failed (\(error)); attempting copy fallback.")
        }

        // Fallback: copy recursively then verify.
        let success = copyWithVerification(from: legacyDataDir, to: newDataDir)
        if success {
            logger("Copy-fallback succeeded. Removing legacy dir.")
            do { try fileOps.removeItem(at: legacyDataDir) } catch {
                logger("Warning: could not remove legacy dir after copy: \(error)")
            }
        } else {
            logger("Copy-fallback had failures — leaving legacy dir intact to prevent data loss.")
        }
        return .copiedFallback(success: success)
    }

    /// Recursively copies `src` to `dst`, verifying file sizes match.
    /// Returns `true` if all files copied and verified successfully.
    private func copyWithVerification(from src: URL, to dst: URL) -> Bool {
        do {
            try fileOps.createDirectory(at: dst)
        } catch {
            logger("Cannot create destination dir \(dst.path): \(error)")
            return false
        }

        guard let children = try? fileOps.contentsOfDirectory(at: src) else {
            logger("Cannot list contents of \(src.path)")
            return false
        }

        var allOK = true
        for child in children {
            let dstChild = dst.appendingPathComponent(child.lastPathComponent)
            // Recurse into subdirectories
            if fileOps.directoryExists(at: child) {
                let ok = copyWithVerification(from: child, to: dstChild)
                if !ok { allOK = false }
            } else {
                // Copy file
                do {
                    try fileOps.copyItem(at: child, to: dstChild)
                    // Verify size — treat an unreadable size (nil) as a
                    // verification failure.  We must never delete the legacy
                    // source unless every file is *positively* verified.
                    let srcSize = fileOps.fileSize(at: child)
                    let dstSize = fileOps.fileSize(at: dstChild)
                    if let s = srcSize, let d = dstSize {
                        if s != d {
                            logger("Size mismatch for \(child.lastPathComponent): src=\(s) dst=\(d)")
                            allOK = false
                        }
                    } else {
                        // At least one side returned nil — cannot confirm integrity.
                        logger("Cannot verify size for \(child.lastPathComponent): src=\(srcSize.map { "\($0)" } ?? "nil") dst=\(dstSize.map { "\($0)" } ?? "nil") — treating as failure")
                        allOK = false
                    }
                } catch {
                    logger("Failed to copy \(child.lastPathComponent): \(error)")
                    allOK = false
                }
            }
        }
        return allOK
    }
}

// MARK: - Keychain migration

extension AppDataMigration {
    /// Migrates Instagram cookies from the legacy service (`com.paragraphos.instagram`)
    /// to the new service (`com.vocateca.instagram`).
    ///
    /// **Self-sufficient**: enumerates all items under the legacy service rather than
    /// requiring the caller to supply account IDs.  This guarantees no cookies are
    /// orphaned even if the watchlist hasn't been loaded yet.
    ///
    /// **Idempotent**: if the new service already contains items, the migration is
    /// skipped entirely to avoid double-writing.  If the legacy service is empty,
    /// the method returns immediately.
    ///
    /// - Parameter keychain: An injectable ``KeychainMigrationOperations`` implementation.
    ///   The production instance is ``SystemKeychainMigrationStore``; tests use a fake.
    public func migrateKeychainIfNeeded(keychain: KeychainMigrationOperations) {
        do {
            // Idempotency guard: if the new service already has items, we're done.
            if try keychain.newServiceHasItems() {
                logger("Keychain already migrated (new service has items) — skipping re-migration.")
                return
            }

            let items = try keychain.enumerateLegacyAccounts()
            guard !items.isEmpty else {
                logger("No legacy Keychain entries found for \(AppDataMigration.legacyKeychainService) — nothing to migrate.")
                return
            }

            logger("Found \(items.count) legacy Keychain item(s) to migrate.")
            for (accountID, data) in items {
                do {
                    try keychain.writeNew(data, account: accountID)
                    try keychain.deleteLegacy(account: accountID)
                    logger("Migrated Keychain cookie for account '\(accountID)' from legacy to new service.")
                } catch {
                    logger("Keychain migration error for account '\(accountID)': \(error)")
                }
            }
        } catch {
            logger("Keychain migration enumeration failed: \(error)")
        }
    }

    // MARK: - Backwards-compatible overload (for callers who supply account IDs)
    //
    // Kept for tests that pre-date the enumeration API.  New code should call
    // `migrateKeychainIfNeeded(keychain:)` without an account list.
    @_disfavoredOverload
    public func migrateKeychainIfNeeded(
        accountIDs: [String],
        keychain: KeychainMigrationOperations
    ) {
        guard !accountIDs.isEmpty else { return }
        for accountID in accountIDs {
            do {
                guard let data = try keychain.readLegacy(account: accountID) else { continue }
                try keychain.writeNew(data, account: accountID)
                try keychain.deleteLegacy(account: accountID)
                logger("Migrated Keychain cookie for account '\(accountID)' from legacy to new service.")
            } catch {
                logger("Keychain migration error for account '\(accountID)': \(error)")
            }
        }
    }
}

// MARK: - Paths extension (no-create variant for migration)

extension Paths {
    /// Returns the new data dir URL **without** creating it.
    /// Used by ``AppDataMigration`` so checking existence doesn't auto-create.
    public static func userDataDirWithoutCreating(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vocateca", isDirectory: true)
    }
}

// MARK: - RealFileMigrationOperations

/// Production implementation that delegates to `FileManager`.
private struct RealFileMigrationOperations: FileMigrationOperations {
    func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        try FileManager.default.moveItem(at: src, to: dst)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )
    }

    func copyItem(at src: URL, to dst: URL) throws {
        try FileManager.default.copyItem(at: src, to: dst)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileSize(at url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? Int64
    }
}

// MARK: - SystemKeychainMigrationStore

/// Production ``KeychainMigrationOperations`` implementation that uses the macOS
/// Security framework.
///
/// - Enumerates *all* generic-password items under `com.paragraphos.instagram`
///   using `SecItemCopyMatching` with `kSecMatchLimitAll`.
/// - Writes each to `com.vocateca.instagram` (via `SystemKeychainStore.set`).
/// - Deletes each from the legacy service.
///
/// **Do not use in unit tests** — this touches the real Keychain.
/// Use ``FakeKeychainOps`` in tests instead.
public struct SystemKeychainMigrationStore: KeychainMigrationOperations {

    public init() {}

    public func enumerateLegacyAccounts() throws -> [(account: String, data: Data)] {
        // NOTE: macOS rejects kSecReturnData together with kSecMatchLimitAll
        // (errSecParam / -50 — you can't return data for many items in one call).
        // So enumerate ATTRIBUTES only to get the account names, then fetch each
        // item's data individually via readLegacy(account:).
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      AppDataMigration.legacyKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        let dicts: [[CFString: Any]]
        switch status {
        case errSecSuccess:
            if let arr = result as? [[CFString: Any]] {
                dicts = arr
            } else if let single = result as? [CFString: Any] {
                dicts = [single]   // a single match may come back as one dict
            } else {
                dicts = []
            }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }

        var out: [(account: String, data: Data)] = []
        for d in dicts {
            guard let account = d[kSecAttrAccount] as? String else { continue }
            if let data = try readLegacy(account: account) {
                out.append((account, data))
            }
        }
        return out
    }

    public func readLegacy(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: AppDataMigration.legacyKeychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedDataFormat }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func writeNew(_ data: Data, account: String) throws {
        // Reuse SystemKeychainStore which targets com.vocateca.instagram.
        try SystemKeychainStore().set(data, account: account)
    }

    public func deleteLegacy(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: AppDataMigration.legacyKeychainService,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func newServiceHasItems() throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      AppDataMigration.newKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:      return true
        case errSecItemNotFound: return false
        default:                 throw KeychainError.unexpectedStatus(status)
        }
    }
}
