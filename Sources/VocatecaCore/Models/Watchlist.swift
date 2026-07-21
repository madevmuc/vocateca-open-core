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
    ///
    /// - Parameter allowDrasticShrink: opt-in for the ONE legitimate
    ///   whole-replace path (an `.overwrite` import). Everywhere else the default
    ///   `false` makes a destructive write throw rather than clobber — see
    ///   ``guardDestructiveWrite(at:allow:)``.
    public func save(to url: URL, allowDrasticShrink: Bool = false) throws {
        try guardDestructiveWrite(at: url, allow: allowDrasticShrink)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = try yamlString()
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    /// Crash-safe write: serialize to a sibling `.tmp` file, then
    /// `FileManager.replaceItem` (equivalent to POSIX `rename`).
    public func saveAtomic(to url: URL, allowDrasticShrink: Bool = false) throws {
        try guardDestructiveWrite(at: url, allow: allowDrasticShrink)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        let text = try yamlString()
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Destructive-write guard (2026-07-16 / hardened 2026-07-21)

    /// Raised when a whole-value save would destroy data on disk and the caller
    /// did not explicitly opt in (`allowDrasticShrink`). The fuller file has been
    /// backed up to `backup` before the write was refused.
    public enum WriteError: Error, Equatable {
        case refusedDestructiveWrite(reason: String, backup: String?)
    }

    /// `true` when writing `new` shows over an on-disk file of `onDisk` shows is a
    /// DRASTIC, suspicious shrink — the signature of a partial in-memory watchlist
    /// silently overwriting the full file (the 18→1 loss that dropped 17 shows to
    /// "orphaned, no artwork"). Deliberately conservative so a normal single
    /// delete never trips it: the file must have held a non-trivial list (≥4),
    /// and the write must drop more than half AND at least 3 shows.
    public static func isDrasticShrink(onDisk: Int, new: Int) -> Bool {
        onDisk >= 4 && new < onDisk && (onDisk - new) >= 3 && new * 2 < onDisk
    }

    /// Slugs whose on-disk entry has a populated `artworkUrl` but whose
    /// same-slug entry in `self` would blank it. A show that SURVIVES a save must
    /// never lose its artwork — that is the exact loss the count-only guard
    /// missed (a 25→17 write blanked every surviving show's artwork, dropping all
    /// thumbnails, without tripping the drastic-shrink threshold). Pure +
    /// testable.
    public static func artworkBlankedSlugs(onDisk: [Show], new: [Show]) -> [String] {
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }
        let newBySlug = Dictionary(new.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        return onDisk.compactMap { old in
            guard filled(old.artworkUrl),
                  let incoming = newBySlug[old.slug],
                  !filled(incoming.artworkUrl) else { return nil }
            return old.slug
        }
    }

    /// Why this whole-value write over `existing` is destructive — `nil` when it
    /// is safe. Two independent signatures: a drastic show-count shrink, and
    /// blanking a surviving show's artwork.
    private func destructiveWriteReason(againstOnDisk existing: Watchlist) -> String? {
        if Self.isDrasticShrink(onDisk: existing.shows.count, new: shows.count) {
            return "drastic shrink \(existing.shows.count)→\(shows.count) shows"
        }
        let blanked = Self.artworkBlankedSlugs(onDisk: existing.shows, new: shows)
        if !blanked.isEmpty {
            return "would blank artwork on \(blanked.count) surviving show(s): \(blanked.prefix(5).joined(separator: ","))"
        }
        return nil
    }

    /// Before overwriting `url`, detect a destructive write. In ALL cases the
    /// existing (fuller) file is snapshotted to a `.pre-shrink-<epoch>.bak`
    /// sibling so the loss is recoverable. Then:
    ///   - `allow == false` (the default): THROW ``WriteError`` so the fuller
    ///     file survives — the write never lands. This is the prevention the old
    ///     backup-only guard lacked: it snapshotted but let the clobber through
    ///     (a non-isolated test writing a 1-show fixture wiped the real
    ///     watchlist; see `swift-tests-must-isolate-via-paths-override`).
    ///   - `allow == true`: log loudly and proceed — the ONE legitimate
    ///     whole-replace (an `.overwrite` import) opts in.
    private func guardDestructiveWrite(at url: URL, allow: Bool) throws {
        guard let existing = try? Watchlist.load(from: url) else { return }
        guard let reason = destructiveWriteReason(againstOnDisk: existing) else { return }
        let backup = url.deletingPathExtension()
            .appendingPathExtension("pre-shrink-\(Int(Date().timeIntervalSince1970)).bak")
        try? FileManager.default.copyItem(at: url, to: backup)
        if allow {
            Log.warn("Watchlist: destructive write allowed by caller — backed the fuller file up first",
                     component: "Watchlist",
                     context: [("reason", reason), ("backup", backup.lastPathComponent)])
            return
        }
        Log.error("Watchlist: REFUSING destructive write — backed the fuller file up, not overwriting",
                  component: "Watchlist",
                  context: [("reason", reason),
                            ("onDiskShows", "\(existing.shows.count)"),
                            ("newShows", "\(shows.count)"),
                            ("backup", backup.lastPathComponent)])
        throw WriteError.refusedDestructiveWrite(reason: reason, backup: backup.lastPathComponent)
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
