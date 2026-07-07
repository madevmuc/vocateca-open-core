import Foundation

/// User-data path resolution for Vocateca (v2).
///
/// The canonical data directory is `~/Library/Application Support/Vocateca`.
/// On first launch after the rename the ``AppDataMigration`` moves any existing
/// `~/Library/Application Support/Paragraphos` content here atomically.
public enum Paths {
    /// Canonical user-data directory. Created on demand.
    ///
    /// NOTE: Do NOT call this before ``AppDataMigration.runIfNeeded()`` completes,
    /// or you may create an empty Vocateca dir that prevents detection of the
    /// legacy Paragraphos dir. ``AppDataMigration`` handles creation of this dir.
    public static func userDataDir(fileManager: FileManager = .default) -> URL {
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
}
