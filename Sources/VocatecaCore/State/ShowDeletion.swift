import Foundation

// MARK: - ShowDeletion

/// Fully removes a show from the app: DB episode rows, `watchlist.yaml` entry,
/// and the on-disk transcript + media directories.
///
/// This is the single seam UI code should call for "delete show" — it exists so
/// that deleting a show is never a partial operation that leaves transcript /
/// media files (i.e. user content) orphaned on disk after the subscription and
/// DB rows are gone.
public enum ShowDeletion {

    /// Fully removes a show: DB episode rows, watchlist entry, on-disk transcript
    /// dir and media dir.
    ///
    /// The DB delete and watchlist remove+save are the operations that can
    /// meaningfully fail (and the caller should surface); filesystem removal is
    /// best-effort — a missing transcript/media directory is not an error, and a
    /// removal failure (e.g. permissions) is logged but does not throw, since the
    /// show has already been fully unsubscribed by that point.
    ///
    /// - Parameters:
    ///   - slug: The ``Show/slug`` to remove.
    ///   - store: The `StateStore` whose `episodes` rows for `slug` are deleted.
    ///   - watchlistURL: Path to `watchlist.yaml` (pass ``Paths/watchlistURL`` in production).
    ///   - outputRoot: Root directory for transcript output (already tilde-expanded).
    ///   - mediaDir: Root directory for downloaded media (already tilde-expanded).
    /// - Throws: Whatever `store.deleteShow` or the watchlist load/save throw.
    public static func deleteShowFully(
        slug: String,
        store: StateStore,
        watchlistURL: URL,
        outputRoot: URL,
        mediaDir: URL
    ) throws {
        try store.deleteShow(slug: slug)

        let wl = try WatchlistStore.load(from: watchlistURL)
        wl.remove(slug: slug)
        try wl.save(to: watchlistURL)

        // Match the writer/downloader's directory naming exactly (see
        // MarkdownLibraryWriter.writePodcastTranscript / URLSessionDownloader.download).
        let dirSlug = TextNormalization.slugify(slug)
        let dirs = [
            outputRoot.appendingPathComponent(dirSlug, isDirectory: true),
            mediaDir.appendingPathComponent(dirSlug, isDirectory: true),
        ]
        for dir in dirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                Log.warn("ShowDeletion: failed to remove dir",
                         component: "Privacy",
                         context: [("dir", dir.path), ("error", "\(error)")])
            }
        }

        Log.info("ShowDeletion: deleted show", component: "Privacy", context: [("slug", slug)])
    }

    /// Trash-backed show deletion (combined danger model): parks the show's
    /// watchlist entry + episode rows + transcript files in „Zuletzt gelöscht" for
    /// 30 days (restorable), then removes the live subscription/DB rows and deletes
    /// the media dir. **Media is not trashed** — only the text (transcripts) is
    /// recoverable, matching the trash model.
    ///
    /// Order matters: snapshot everything and MOVE the transcript files into the
    /// trash FIRST (so `deleteShow`'s dir removal can't erase them), then remove
    /// the watchlist entry, DB rows, and the media directory.
    ///
    /// - Returns: the created trash-item id (for logging), or nil if the show had
    ///   no watchlist entry to snapshot.
    @discardableResult
    public static func deleteShowToTrash(
        slug: String,
        store: StateStore,
        trash: TrashStore,
        watchlistURL: URL,
        outputRoot: URL,
        mediaDir: URL
    ) throws -> String? {
        // 1) Snapshot the watchlist entry (settings incl. overrides).
        let wl = try WatchlistStore.load(from: watchlistURL)
        guard let show = wl.watchlist.shows.first(where: { $0.slug == slug }) else {
            // No watchlist entry (DB-only orphan): fall back to the direct delete —
            // there's no subscription snapshot to park, and re-adding it on restore
            // would be meaningless.
            try deleteShowFully(slug: slug, store: store, watchlistURL: watchlistURL,
                                outputRoot: outputRoot, mediaDir: mediaDir)
            return nil
        }

        // 2) Snapshot every episode row + capture plain text for the FTS re-index.
        let episodes = (try? store.episodes(showSlug: slug)) ?? []
        let dirSlug = TextNormalization.slugify(slug)
        let showDir = outputRoot.appendingPathComponent(dirSlug, isDirectory: true)

        // Collect the show's transcript files (all sidecars) + per-guid plain text.
        var files: [URL] = []
        var plainByGuid: [String: String] = [:]
        for ep in episodes {
            guard let md = LibraryIndex.resolveTranscriptURL(for: ep, outputRoot: outputRoot) else { continue }
            let base = md.deletingPathExtension()
            let sidecars = [md, base.appendingPathExtension("srt"),
                            base.appendingPathExtension("txt"), base.appendingPathExtension("html")]
            files.append(contentsOf: sidecars.filter { FileManager.default.fileExists(atPath: $0.path) })
            let srt = base.appendingPathExtension("srt")
            if let s = try? String(contentsOf: srt, encoding: .utf8), !s.isEmpty {
                plainByGuid[ep.guid] = TranscriptFormat.srtToPlainText(s)
            } else if let m = try? String(contentsOf: md, encoding: .utf8) {
                plainByGuid[ep.guid] = TranscriptFormat.txtFromMarkdown(m)
            }
        }

        // 3) Park it all in the trash (moves the transcript files out of `showDir`).
        let id = try trash.putShow(show: show, episodes: episodes, files: files,
                                   plainTextByGuid: plainByGuid)

        // 4) Now perform the live removal: DB rows + FTS, watchlist entry, media dir.
        //    Transcript files were already moved into the trash above, so the
        //    (best-effort) `showDir` removal below only clears whatever remained.
        try store.deleteShow(slug: slug)
        wl.remove(slug: slug)
        try wl.save(to: watchlistURL)

        for dir in [showDir, mediaDir.appendingPathComponent(dirSlug, isDirectory: true)] {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do { try FileManager.default.removeItem(at: dir) }
            catch {
                Log.warn("ShowDeletion: failed to remove dir (post-trash)", component: "Privacy",
                         context: [("dir", dir.path), ("error", "\(error)")])
            }
        }

        Log.info("ShowDeletion: deleted show to trash", component: "Privacy",
                 context: [("slug", slug), ("trashID", id), ("episodes", "\(episodes.count)")])
        return id
    }
}
