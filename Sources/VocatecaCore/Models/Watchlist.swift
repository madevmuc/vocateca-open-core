import Foundation
import Yams

// MARK: - Watchlist

/// Container for all podcast/YouTube/local shows.
///
/// Oracle-locked port of `core/models.py :: Watchlist`.
/// Shape: `{ shows: [Show] }`.
public struct Watchlist: Codable, Sendable, Equatable {
    public var shows: [Show]

    public init(shows: [Show] = []) {
        self.shows = shows
    }

    // MARK: - Load

    /// Load from a YAML file at `url`.  If the file does not exist, returns
    /// an empty ``Watchlist`` — matching Python's `if not path.exists(): return cls()`.
    ///
    /// Throws on malformed YAML or field-type mismatches.
    public static func load(from url: URL) throws -> Watchlist {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Watchlist()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Watchlist.self, from: text)
    }

    // MARK: - Save helpers

    /// Encode to a YAML string (suitable for writing to disk).
    public func yamlString() throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(self)
    }

    /// Write to `url`, creating parent directories as needed.
    /// Does NOT use atomic write — callers that need crash-safety should
    /// use `saveAtomic(to:)`.
    public func save(to url: URL) throws {
        backupIfDrasticShrink(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = try yamlString()
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    /// Crash-safe write: serialize to a sibling `.tmp` file, then
    /// `FileManager.replaceItem` (equivalent to POSIX `rename`).
    public func saveAtomic(to url: URL) throws {
        backupIfDrasticShrink(at: url)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        let text = try yamlString()
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Drastic-shrink guard (2026-07-16 data-loss prevention)

    /// `true` when writing `new` shows over an on-disk file of `onDisk` shows is a
    /// DRASTIC, suspicious shrink — the signature of a partial in-memory watchlist
    /// silently overwriting the full file (the 18→1 loss that dropped 17 shows to
    /// "orphaned, no artwork"). Deliberately conservative so a normal single
    /// delete never trips it: the file must have held a non-trivial list (≥4),
    /// and the write must drop more than half AND at least 3 shows.
    public static func isDrasticShrink(onDisk: Int, new: Int) -> Bool {
        onDisk >= 4 && new < onDisk && (onDisk - new) >= 3 && new * 2 < onDisk
    }

    /// Before overwriting `url`, snapshot the existing file to a
    /// `.pre-shrink-<epoch>.bak` sibling and log loudly when the write would be a
    /// drastic shrink (``isDrasticShrink``) — so the loss is recoverable and
    /// visible instead of silent. Best-effort: never blocks or fails the save
    /// (the guard must not itself break a legitimate write).
    private func backupIfDrasticShrink(at url: URL) {
        guard let existing = try? Watchlist.load(from: url) else { return }
        guard Self.isDrasticShrink(onDisk: existing.shows.count, new: shows.count) else { return }
        let backup = url.deletingPathExtension()
            .appendingPathExtension("pre-shrink-\(Int(Date().timeIntervalSince1970)).bak")
        try? FileManager.default.copyItem(at: url, to: backup)
        Log.error("Watchlist: refusing to SILENTLY drop shows — backed up the fuller file before save",
                  component: "Watchlist",
                  context: [("onDiskShows", "\(existing.shows.count)"),
                            ("newShows", "\(shows.count)"),
                            ("backup", backup.lastPathComponent)])
    }
}

// MARK: - SettingsStore

/// Load/save helpers for ``Settings``, mirroring Python's `Settings.load` / `Settings.save`.
public enum SettingsStore {

    /// Load from a YAML file at `url`.
    ///
    /// Applies the legacy ``Settings/migratingLoadLevel(in:)`` migration and
    /// ``Settings/applyingBackfillSetupCompleted()`` post-load, exactly as the
    /// Python reference does.
    ///
    /// If the file does not exist, returns a ``Settings`` with all Python
    /// defaults applied. When `persistDefaultOnMissing` is `true` (the Python
    /// default behaviour) it also writes the defaults to `url`, swallowing a
    /// write error (e.g. read-only FS). Pass `false` for a guaranteed
    /// **read-only** load — used by oracle/round-trip tests so a missing file
    /// can never cause a write into a real data directory.
    public static func load(from url: URL, persistDefaultOnMissing: Bool = true) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let s = Settings()
            if persistDefaultOnMissing {
                try? save(s, to: url)
            }
            return s.applyingBackfillSetupCompleted()
        }
        var text = try String(contentsOf: url, encoding: .utf8)
        text = try Settings.migratingLoadLevel(in: text)
        let decoder = YAMLDecoder()
        var s = try decoder.decode(Settings.self, from: text)
        s = s.applyingBackfillSetupCompleted()
        return s
    }

    /// Write ``Settings`` to `url` as YAML.
    public static func save(_ settings: Settings, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = try yamlString(settings)
        // Atomic write (temp + rename) so a concurrent/debounced writer or a
        // mid-write crash can never leave a torn settings.yaml.
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.info("Settings saved", component: "Settings",
                 context: [("engine", settings.transcriptionEngine),
                            ("bytes", "\(text.utf8.count)")])
    }

    /// Encode ``Settings`` to a YAML string.
    public static func yamlString(_ settings: Settings) throws -> String {
        try YAMLEncoder().encode(settings)
    }

    /// Decode ``Settings`` from a YAML string (no migration, no backfill).
    public static func decode(from yaml: String) throws -> Settings {
        try YAMLDecoder().decode(Settings.self, from: yaml)
    }
}
