import Foundation

/// User-data path resolution for Vocateca (v2).
///
/// The canonical data directory is `~/Library/Application Support/Vocateca`.
/// On first launch after the rename the ``AppDataMigration`` moves any existing
/// `~/Library/Application Support/Paragraphos` content here atomically.
public enum Paths {
    /// M-3 (2.0.4-batch): test-only override for ``userDataDir(fileManager:)``.
    /// When non-nil, every path derived from `userDataDir()` — `stateDatabaseURL`,
    /// `watchlistURL`, `settingsURL`, etc. — resolves under this directory
    /// instead of the real `~/Library/Application Support/Vocateca`, so a test
    /// can point the whole `Paths` surface at an isolated empty temp dir
    /// without touching the user's real (potentially huge) library. `nil` in
    /// production and by default in tests. A test that sets this MUST save the
    /// previous value and restore it in `tearDown`/`tearDownWithError`.
    ///
    /// `nonisolated(unsafe)`: mutated only from a single test's
    /// `setUp`/`tearDown` (which happen-before/-after that test's actual
    /// work), never concurrently with another test.
    nonisolated(unsafe) public static var testOverrideUserDataDir: URL?

    /// Canonical user-data directory. Created on demand.
    ///
    /// NOTE: Do NOT call this before ``AppDataMigration.runIfNeeded()`` completes,
    /// or you may create an empty Vocateca dir that prevents detection of the
    /// legacy Paragraphos dir. ``AppDataMigration`` handles creation of this dir.
    public static func userDataDir(fileManager: FileManager = .default) -> URL {
        if let override = testOverrideUserDataDir {
            try? fileManager.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let dir = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vocateca", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The legacy Paragraphos data directory (v1 / pre-rename location).
    /// Used by ``AppDataMigration`` to detect and migrate existing user data.
    public static func legacyDataDir(fileManager: FileManager = .default) -> URL {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paragraphos", isDirectory: true)
    }

    public static var stateDatabaseURL: URL { userDataDir().appendingPathComponent("state.sqlite") }
    /// Swift-owned notifications database. Separate from state.sqlite (Python-co-owned).
    public static var notificationsDatabaseURL: URL { userDataDir().appendingPathComponent("notifications.sqlite") }
    public static var settingsURL: URL { userDataDir().appendingPathComponent("settings.yaml") }
    public static var watchlistURL: URL { userDataDir().appendingPathComponent("watchlist.yaml") }
    /// YouTube Explorer's tab-local "recently opened" history — UI-only (not
    /// the Library, not a DB show), a plain JSON blob.
    public static var youtubeExplorerHistoryURL: URL {
        userDataDir().appendingPathComponent("youtube_explorer_history.json")
    }
}
