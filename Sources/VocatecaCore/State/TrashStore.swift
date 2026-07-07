import Foundation
import GRDB

// MARK: - TrashItem

/// One row in the „Zuletzt gelöscht" (recently-deleted) trash — a deleted
/// transcript or show parked for 30 days before final erasure.
///
/// The UI renders `title` + a relative "deleted / auto-removes" line derived from
/// `deletedAt`; `kind` drives the restore path (transcript vs show). `fileCount`
/// is a cheap display hint (how many transcript files were parked).
public struct TrashItem: Sendable, Equatable, Identifiable {
    /// One of ``TrashKind``'s raw values (`"transcript"` | `"show"`).
    public enum Kind: String, Sendable, Equatable {
        case transcript
        case show
    }

    public let id: String
    public let kind: Kind
    /// Episode GUID (transcript kind) or the show slug (show kind).
    public let guid: String
    public let showSlug: String
    public let title: String
    /// ISO-8601 UTC timestamp the item was moved to trash.
    public let deletedAt: String
    /// Number of transcript files parked under `trash/<id>/`.
    public let fileCount: Int

    public init(id: String, kind: Kind, guid: String, showSlug: String,
                title: String, deletedAt: String, fileCount: Int) {
        self.id = id
        self.kind = kind
        self.guid = guid
        self.showSlug = showSlug
        self.title = title
        self.deletedAt = deletedAt
        self.fileCount = fileCount
    }
}

// MARK: - Trash payload snapshots

/// Snapshot stored in `trash_items.payload_json` for a trashed transcript — the
/// DB state `restore` must put back.
struct TrashTranscriptPayload: Codable, Sendable {
    /// The original `transcript_path` column value (absolute path) to restore.
    var transcriptPath: String?
    /// The `status` the episode had before deletion (e.g. `"done"`) — restored so
    /// the episode leaves the `skipped` state the delete set.
    var priorStatus: String
    /// Plain-text transcript content used to re-index FTS on restore (captured at
    /// delete time so restore never depends on re-reading a moved file).
    var plainText: String
}

/// Snapshot stored in `trash_items.payload_json` for a trashed show — the
/// watchlist entry + episode rows `restore` must recreate.
struct TrashShowPayload: Codable, Sendable {
    /// The watchlist `Show` entry (settings incl. overrides) to re-add.
    var show: Show
    /// Every episode row for the show, to re-insert on restore.
    var episodes: [Episode]
    /// Plain-text transcript content per episode guid, used to re-index FTS on
    /// restore for episodes that had a transcript.
    var plainTextByGuid: [String: String]
}

/// One moved transcript file: where it lived and its stored basename under
/// `trash/<id>/`. Stored (as a list) in `trash_items.files_json`.
struct TrashFile: Codable, Sendable {
    /// Absolute original path the file must be moved back to on restore.
    var original: String
    /// Basename of the copy under `trash/<id>/`.
    var stored: String
}

// MARK: - TrashStore

/// Owns the „Zuletzt gelöscht" trash: the `trash_items` table + the on-disk
/// `<userDataDir>/trash/<id>/` directories that hold the moved transcript files,
/// plus the deferred-media (`trash_pending_media`) table.
///
/// ## Danger model
/// A single-transcript or show deletion COMMITS immediately — the transcript
/// files MOVE into the trash and the DB is updated — and „Rückgängig" / the
/// „Zuletzt gelöscht" list restore them. The associated **media (mp3) is NOT
/// trashed**: it is scheduled for final deletion once the undo window elapses
/// (`trash_pending_media.ready_at`), so app-quit during the window is safe by
/// construction (the next-launch `MaintenanceRunner` finalize sweep completes
/// it). Trash keeps only text + metadata.
///
/// AppKit/SwiftUI-free — lives in `VocatecaCore` and is called from the UI's
/// delete seams. Every mutation logs (`Log.*`) with kind + guid.
///
/// Not `Sendable` (it stores a `FileManager`, which isn't) — mirrors
/// ``MaintenanceRunner``. Construct it inside the task/actor that uses it (like
/// the Library search opens its `StateStore` inside a detached task) rather than
/// capturing one across a boundary.
public struct TrashStore {

    private let store: StateStore
    /// Root directory for parked files (`<userDataDir>/trash`). Created on demand.
    private let trashDir: URL
    private let fileManager: FileManager

    public init(store: StateStore, trashDir: URL, fileManager: FileManager = .default) {
        self.store = store
        self.trashDir = trashDir
        self.fileManager = fileManager
    }

    /// Production convenience: trash lives at `<userDataDir>/trash`.
    public static func production(store: StateStore) -> TrashStore {
        TrashStore(store: store,
                   trashDir: Paths.userDataDir().appendingPathComponent("trash", isDirectory: true))
    }

    // MARK: - Put: transcript

    /// Moves a deleted transcript's files into the trash and records the row, so
    /// the delete is reversible for 30 days. Also schedules the episode's media
    /// (mp3) for final deletion once `undoWindowSeconds` elapse (media is not
    /// trashed).
    ///
    /// The caller is responsible for the `episodes` DB mutation that removes the
    /// live transcript (`StateStore.clearTranscriptAndSkip`, which also drops the
    /// FTS row) — this method only parks the files + metadata. `restore(id:)`
    /// inverts both.
    ///
    /// - Parameters:
    ///   - episode: The episode whose transcript is being deleted.
    ///   - files: The transcript sidecar files to move (`.md`/`.srt`/`.txt`/`.html`).
    ///   - priorStatus: The episode's `status` before deletion (restored on undo).
    ///   - plainText: Plain-text content for the FTS re-index on restore.
    ///   - mediaPath: The episode's `mp3_path` (scheduled for deferred deletion), or nil.
    ///   - undoWindowSeconds: Grace period before the media is finally deleted.
    ///   - nowISO: Injectable clock.
    /// - Returns: The new trash-item id.
    @discardableResult
    public func putTranscript(
        episode: Episode,
        files: [URL],
        priorStatus: String,
        plainText: String,
        mediaPath: String?,
        undoWindowSeconds: Int = 6,
        nowISO: String = Event.nowISO()
    ) throws -> String {
        let id = UUID().uuidString
        let stored = try moveFilesIntoTrash(id: id, files: files)

        let payload = TrashTranscriptPayload(
            transcriptPath: episode.transcriptPath,
            priorStatus: priorStatus,
            plainText: plainText
        )
        try insertItem(id: id, kind: .transcript, guid: episode.guid,
                       showSlug: episode.showSlug, title: episode.title,
                       payload: payload, files: stored, deletedAt: nowISO)

        // Schedule the media (mp3) for deferred final-deletion — it is NOT parked.
        if let mediaPath, !mediaPath.isEmpty {
            let readyAt = Event.iso(from: Event.date(fromISO: nowISO).addingTimeInterval(TimeInterval(undoWindowSeconds)))
            try schedulePendingMedia(guid: episode.guid, mediaPath: mediaPath, readyAt: readyAt)
        }

        Log.info("Trash: put transcript", component: "Trash",
                 context: [("id", id), ("guid", episode.guid), ("slug", episode.showSlug),
                            ("files", "\(stored.count)")])
        return id
    }

    // MARK: - Put: show

    /// Moves a deleted show's transcript files into the trash and records the row.
    /// The show's watchlist entry + episode rows are snapshotted so restore can
    /// recreate them. Media is not trashed (the caller deletes the media dir).
    ///
    /// - Parameters:
    ///   - show: The watchlist `Show` entry being removed (settings incl. overrides).
    ///   - episodes: All episode rows for the show (snapshotted for restore).
    ///   - files: The show's transcript files to move.
    ///   - plainTextByGuid: Plain-text per episode guid for the FTS re-index on restore.
    ///   - nowISO: Injectable clock.
    /// - Returns: The new trash-item id.
    @discardableResult
    public func putShow(
        show: Show,
        episodes: [Episode],
        files: [URL],
        plainTextByGuid: [String: String],
        nowISO: String = Event.nowISO()
    ) throws -> String {
        let id = UUID().uuidString
        let stored = try moveFilesIntoTrash(id: id, files: files)

        let payload = TrashShowPayload(show: show, episodes: episodes, plainTextByGuid: plainTextByGuid)
        try insertItem(id: id, kind: .show, guid: show.slug, showSlug: show.slug,
                       title: show.displayName, payload: payload, files: stored, deletedAt: nowISO)

        Log.info("Trash: put show", component: "Trash",
                 context: [("id", id), ("slug", show.slug), ("episodes", "\(episodes.count)"),
                            ("files", "\(stored.count)")])
        return id
    }

    // MARK: - Restore

    /// Restores a trashed item: moves its files back to their original locations,
    /// re-creates the DB state (transcript row / watchlist entry + episode rows),
    /// re-indexes FTS, and — for a transcript — cancels the pending media delete.
    /// The trash row + parked directory are removed on success.
    ///
    /// - Parameter watchlistURL: Path to `watchlist.yaml` (needed for show restore).
    /// - Returns: The restored ``TrashItem`` (for logging / a follow-up reload), or
    ///   nil when `id` is not in the trash.
    @discardableResult
    public func restore(id: String, watchlistURL: URL) throws -> TrashItem? {
        guard let row = try fetchRow(id: id) else { return nil }
        let files = try decodeFiles(row.filesJSON)

        switch row.kind {
        case .transcript:
            try restoreFiles(id: id, files: files)
            let payload = try JSONDecoder().decode(TrashTranscriptPayload.self,
                                                   from: Data(row.payloadJSON.utf8))
            try store.restoreTranscript(guid: row.guid,
                                        transcriptPath: payload.transcriptPath,
                                        status: payload.priorStatus)
            // Re-index FTS from the captured plain text so a restored transcript is
            // searchable again immediately.
            try? store.indexTranscript(guid: row.guid, showSlug: row.showSlug,
                                       title: row.title, content: payload.plainText)
            try cancelPendingMedia(guid: row.guid)

        case .show:
            try restoreFiles(id: id, files: files)
            let payload = try JSONDecoder().decode(TrashShowPayload.self,
                                                   from: Data(row.payloadJSON.utf8))
            // Re-add the watchlist entry.
            let wl = try WatchlistStore.load(from: watchlistURL)
            _ = wl.add(payload.show)
            try wl.save(to: watchlistURL)
            // Re-insert episode rows + re-index the ones that had a transcript.
            for ep in payload.episodes {
                try store.upsert(ep)
                if let text = payload.plainTextByGuid[ep.guid] {
                    try? store.indexTranscript(guid: ep.guid, showSlug: ep.showSlug,
                                               title: ep.title, content: text)
                }
            }
        }

        try deleteRow(id: id)
        removeTrashDir(id: id)
        Log.info("Trash: restore", component: "Trash",
                 context: [("id", id), ("kind", row.kind.rawValue), ("guid", row.guid)])
        return TrashItem(id: id, kind: row.kind, guid: row.guid, showSlug: row.showSlug,
                         title: row.title, deletedAt: row.deletedAt, fileCount: files.count)
    }

    // MARK: - Delete now (irreversible)

    /// Permanently erases one trashed item now: removes its parked files + the DB
    /// row. Irreversible — the UI gates this behind an explicit confirm.
    public func deleteNow(id: String) throws {
        guard let row = try fetchRow(id: id) else { return }
        removeTrashDir(id: id)
        try deleteRow(id: id)
        // A transcript's deferred media may still be pending — erase it now too.
        if row.kind == .transcript {
            try? finalizeOnePendingMedia(guid: row.guid)
        }
        Log.info("Trash: deleteNow", component: "Trash",
                 context: [("id", id), ("kind", row.kind.rawValue), ("guid", row.guid)])
    }

    // MARK: - Purge (30-day age-out)

    /// Permanently erases every trashed item older than `days` (default 30). Wired
    /// into `MaintenanceRunner.run()`. Best-effort per item; returns the count
    /// purged.
    @discardableResult
    public func purge(olderThanDays days: Int = 30, nowISO: String = Event.nowISO()) throws -> Int {
        let cutoff = Event.iso(from: Event.date(fromISO: nowISO).addingTimeInterval(-TimeInterval(days) * 86_400))
        let rows = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM trash_items WHERE deleted_at < ?", arguments: [cutoff])
        }
        var purged = 0
        for r in rows {
            let id: String = r["id"]
            removeTrashDir(id: id)
            try? deleteRow(id: id)
            purged += 1
            Log.info("Trash: purged (age-out)", component: "Trash",
                     context: [("id", id), ("cutoffDays", "\(days)")])
        }
        return purged
    }

    // MARK: - Deferred media finalize

    /// Deletes every media (mp3) file whose deferred-delete window has elapsed
    /// (`ready_at <= now`), clears its `mp3_path`, and removes the pending row.
    /// Called by the toast on expiry AND by the next-launch `MaintenanceRunner`
    /// sweep (app-quit-safe). Returns the number of media files erased.
    @discardableResult
    public func finalizePendingMedia(nowISO: String = Event.nowISO()) throws -> Int {
        let rows = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT guid, media_path FROM trash_pending_media WHERE ready_at <= ?",
                             arguments: [nowISO])
        }
        var finalized = 0
        for r in rows {
            let guid: String = r["guid"]
            let path: String = r["media_path"]
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
            try? store.clearMp3Path(guid: guid)
            try? cancelPendingMedia(guid: guid)
            finalized += 1
            Log.info("Trash: finalize media delete (window elapsed)", component: "Trash",
                     context: [("guid", guid)])
        }
        return finalized
    }

    // MARK: - Query

    /// All trash items, newest-deleted first.
    public func items() throws -> [TrashItem] {
        try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, guid, show_slug, title, files_json, deleted_at
                FROM trash_items ORDER BY deleted_at DESC
            """).map { row in
                let filesJSON: String = row["files_json"] ?? "[]"
                let count = ((try? JSONDecoder().decode([TrashFile].self, from: Data(filesJSON.utf8)))?.count) ?? 0
                return TrashItem(
                    id: row["id"],
                    kind: TrashItem.Kind(rawValue: row["kind"]) ?? .transcript,
                    guid: row["guid"] ?? "",
                    showSlug: row["show_slug"] ?? "",
                    title: row["title"] ?? "",
                    deletedAt: row["deleted_at"] ?? "",
                    fileCount: count
                )
            }
        }
    }

    /// Count of trash items (drives the „Zuletzt gelöscht (%lld)" pane-1 entry;
    /// the entry is hidden when this is 0).
    public func count() throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trash_items") ?? 0
        }
    }

    // MARK: - Private: DB rows

    private struct TrashRow {
        let kind: TrashItem.Kind
        let guid: String
        let showSlug: String
        let title: String
        let payloadJSON: String
        let filesJSON: String
        let deletedAt: String
    }

    private func fetchRow(id: String) throws -> TrashRow? {
        try store.dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT kind, guid, show_slug, title, payload_json, files_json, deleted_at
                FROM trash_items WHERE id = ?
            """, arguments: [id]) else { return nil }
            return TrashRow(
                kind: TrashItem.Kind(rawValue: row["kind"]) ?? .transcript,
                guid: row["guid"] ?? "",
                showSlug: row["show_slug"] ?? "",
                title: row["title"] ?? "",
                payloadJSON: row["payload_json"] ?? "{}",
                filesJSON: row["files_json"] ?? "[]",
                deletedAt: row["deleted_at"] ?? ""
            )
        }
    }

    private func insertItem<P: Encodable>(
        id: String, kind: TrashItem.Kind, guid: String, showSlug: String, title: String,
        payload: P, files: [TrashFile], deletedAt: String
    ) throws {
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let filesJSON = String(decoding: try JSONEncoder().encode(files), as: UTF8.self)
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO trash_items (id, kind, guid, show_slug, title, payload_json, files_json, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, kind.rawValue, guid, showSlug, title, payloadJSON, filesJSON, deletedAt])
        }
    }

    private func deleteRow(id: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM trash_items WHERE id = ?", arguments: [id])
        }
    }

    private func schedulePendingMedia(guid: String, mediaPath: String, readyAt: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO trash_pending_media (guid, media_path, ready_at) VALUES (?, ?, ?)
                ON CONFLICT(guid) DO UPDATE SET media_path = excluded.media_path, ready_at = excluded.ready_at
            """, arguments: [guid, mediaPath, readyAt])
        }
    }

    private func cancelPendingMedia(guid: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM trash_pending_media WHERE guid = ?", arguments: [guid])
        }
    }

    /// Erases the pending media for one guid immediately, ignoring `ready_at`
    /// (used by `deleteNow`, which is an explicit irreversible erase).
    private func finalizeOnePendingMedia(guid: String) throws {
        let path: String? = try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT media_path FROM trash_pending_media WHERE guid = ?",
                             arguments: [guid])?["media_path"]
        }
        if let path, fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        try? store.clearMp3Path(guid: guid)
        try cancelPendingMedia(guid: guid)
    }

    private func decodeFiles(_ json: String) throws -> [TrashFile] {
        (try? JSONDecoder().decode([TrashFile].self, from: Data(json.utf8))) ?? []
    }

    // MARK: - Private: file moves

    /// Moves each URL into `trash/<id>/`, returning the `[TrashFile]` mapping.
    /// Best-effort per file — a missing source is skipped (already gone is fine);
    /// a same-volume `moveItem` keeps the operation atomic + fast.
    private func moveFilesIntoTrash(id: String, files: [URL]) throws -> [TrashFile] {
        let dir = trashDir.appendingPathComponent(id, isDirectory: true)
        var mapping: [TrashFile] = []
        var didCreateDir = false
        for url in files where fileManager.fileExists(atPath: url.path) {
            if !didCreateDir {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                didCreateDir = true
            }
            let base = url.lastPathComponent
            let dest = dir.appendingPathComponent(base)
            // Avoid a collision if two source files share a basename (rare).
            let finalDest = fileManager.fileExists(atPath: dest.path)
                ? dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(base)")
                : dest
            do {
                try fileManager.moveItem(at: url, to: finalDest)
                mapping.append(TrashFile(original: url.path, stored: finalDest.lastPathComponent))
            } catch {
                Log.warn("Trash: file move failed", component: "Trash",
                         context: [("src", url.path), ("error", "\(error)")])
            }
        }
        return mapping
    }

    /// Moves each parked file back to its original location. Best-effort; recreates
    /// the destination directory if the show folder was removed.
    private func restoreFiles(id: String, files: [TrashFile]) throws {
        let dir = trashDir.appendingPathComponent(id, isDirectory: true)
        for f in files {
            let src = dir.appendingPathComponent(f.stored)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dest = URL(fileURLWithPath: f.original)
            try? fileManager.createDirectory(at: dest.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            // Remove any file that reappeared at the destination so the move succeeds.
            if fileManager.fileExists(atPath: dest.path) {
                try? fileManager.removeItem(at: dest)
            }
            do {
                try fileManager.moveItem(at: src, to: dest)
            } catch {
                Log.warn("Trash: file restore failed", component: "Trash",
                         context: [("dest", dest.path), ("error", "\(error)")])
            }
        }
    }

    /// Removes `trash/<id>/` and its contents (best-effort).
    private func removeTrashDir(id: String) {
        let dir = trashDir.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try? fileManager.removeItem(at: dir)
        }
    }
}
