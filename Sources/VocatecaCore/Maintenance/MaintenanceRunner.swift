import Foundation

// MARK: - MaintenanceReport

/// Outcome of one maintenance pass — logged and (for `shouldPauseForDisk`) fed to
/// the queue coordinator.
public struct MaintenanceReport: Sendable, Equatable {
    public var mp3sDeleted: Int = 0
    public var bytesReclaimed: Int64 = 0
    public var transcriptsDeleted: Int = 0
    public var eventsPruned: Int = 0
    public var freeBytes: Int64 = 0
    public var shouldPauseForDisk: Bool = false
    /// Number of media files evicted by the global storage-cap pass (§2 of the
    /// media-retention brief). Runs AFTER the age-based mp3 pass, so these are
    /// files that survived age-out but still pushed the media dir over the cap.
    public var capEvictedCount: Int = 0
    /// Bytes freed by the storage-cap eviction pass.
    public var capFreedBytes: Int64 = 0
    /// `true` when the media dir was at/above 90% of the cap BEFORE eviction —
    /// drives the `storageWarning` notification regardless of whether eviction
    /// itself then ran (cap may be disabled while still near full).
    public var capNearFull: Bool = false
    /// Total media bytes on disk at the time of the cap check, BEFORE eviction.
    /// Only populated when `mediaStorageCapEnabled`; `0` otherwise. Feeds the
    /// `storageWarning` notification's "X GB of Y GB" message.
    public var capUsedBytes: Int64 = 0
    /// Number of „Zuletzt gelöscht" trash items purged past the 30-day window.
    public var trashPurged: Int = 0
    /// Number of deferred media (mp3) files finalized (deleted) because their undo
    /// window elapsed while the app was closed (next-launch finalize sweep).
    public var trashMediaFinalized: Int = 0
}

// MARK: - MaintenanceRunner

/// Executes the retention / disk-hygiene pass: reclaims downloaded mp3s, prunes
/// the events table, and evaluates the disk-space guard. Decisions come from the
/// pure ``RetentionPolicy`` / ``DiskGuard``; this applies them against the DB and
/// filesystem. Best-effort throughout — a single file error never aborts the pass.
///
/// Wires `Settings.deleteMp3AfterTranscribe`, `mp3RetentionDays`,
/// `transcriptRetentionDays`, `eventRetentionDays`, `diskGuardEnabled`,
/// `diskGuardMinFreeGb`.
public struct MaintenanceRunner {

    private let store: StateStore
    private let settings: Settings
    private let fileManager: FileManager
    /// The volume whose free space the disk guard checks (defaults to the media dir).
    private let guardPath: String
    /// Per-show media-retention overrides, keyed by show slug (`Show.mediaRetentionOverrideDays`).
    /// Shows absent from the map follow the global policy. Empty by default (back-compat).
    private let overrideBySlug: [String: Int]
    /// Optional override for the media directory used by the one-time `mp3_path`
    /// backfill sweep. `nil` (production) → `<userDataDir>/media`. Tests inject a
    /// temp dir so the sweep can be exercised without the real data directory.
    private let mediaDirOverride: URL?
    /// Optional override for the „Zuletzt gelöscht" trash directory used by the
    /// purge + deferred-media finalize passes. `nil` (production) →
    /// `<userDataDir>/trash`. Tests inject a temp dir so the passes never touch the
    /// real user trash.
    private let trashDirOverride: URL?

    public init(
        store: StateStore,
        settings: Settings,
        fileManager: FileManager = .default,
        guardPath: String? = nil,
        overrideBySlug: [String: Int] = [:],
        mediaDirOverride: URL? = nil,
        trashDirOverride: URL? = nil
    ) {
        self.store = store
        self.settings = settings
        self.fileManager = fileManager
        self.guardPath = guardPath
            ?? (settings.outputRoot as NSString).expandingTildeInPath
        self.overrideBySlug = overrideBySlug
        self.mediaDirOverride = mediaDirOverride
        self.trashDirOverride = trashDirOverride
    }

    /// `meta` key marking the one-time media-path backfill as done, so the
    /// (potentially thousands-of-files) directory reconstruction runs at most once
    /// per database rather than on every 6-hour maintenance tick.
    static let mp3BackfillDoneMetaKey = "mp3_path_backfill_v1_done"

    /// `meta` key marking the one-time transcript full-text-search backfill as
    /// done. `transcripts_fts` was added after transcripts already existed on
    /// disk, so — like `mp3_path` — pre-existing transcripts are invisible to the
    /// Library search until indexed. This sweep reads each on-disk transcript once
    /// and upserts it into the FTS index; the flag keeps it from re-reading the
    /// whole library on every 6-hour tick.
    static let ftsBackfillDoneMetaKey = "transcript_fts_backfill_v1_done"

    /// Runs a full pass. `nowISO` is injectable for tests; production passes
    /// `Event.nowISO()`.
    @discardableResult
    public func run(nowISO: String = Event.nowISO()) -> MaintenanceReport {
        var report = MaintenanceReport()

        // 0) One-time media-path backfill. `mp3_path` was historically never
        // written by the pipeline, so pre-existing downloaded files are invisible
        // to every retention pass below (they filter `WHERE mp3_path IS NOT NULL`).
        // Reconstruct each missing path from the download naming convention
        // (`<mediaDir>/<slugify(showSlug)>/<makeSlug(guid)>.mp3`) and record it
        // where the file actually exists on disk. Guarded by a `meta` flag so it
        // runs at most once per DB.
        backfillMp3PathsOnce()

        // 0b) One-time transcript full-text-search backfill. `transcripts_fts` was
        // added after transcripts already existed on disk, so pre-existing
        // transcripts are invisible to the Library search until indexed. Read each
        // on-disk transcript once and upsert it into the FTS index. Same
        // meta-flag-guarded one-time pattern as the mp3 backfill above.
        backfillTranscriptFTSOnce()

        // 1) Reclaim downloaded mp3s per the per-show retention policy.
        let candidates = (try? store.mp3RetentionCandidates(
            overrideBySlug: overrideBySlug,
            globalDays: settings.mp3RetentionDays,
            globalDeleteAfterTranscribe: settings.deleteMp3AfterTranscribe,
            nowISO: nowISO)) ?? []
        for c in candidates {
            let path = c.mp3Path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            if fileManager.fileExists(atPath: path) {
                do { try fileManager.removeItem(atPath: path) }
                catch {
                    Log.debug("Maintenance: mp3 delete failed", component: "Maintenance",
                              context: [("path", path), ("error", "\(error)")])
                    continue
                }
            }
            try? store.clearMp3Path(guid: c.guid)
            report.mp3sDeleted += 1
            report.bytesReclaimed += (size ?? 0)
            Log.info("Retention: reclaimed media", component: "Maintenance",
                     context: [("guid", c.guid), ("slug", c.showSlug)])
        }

        // 1b) Global storage cap (NEW): AFTER the age pass above, so already
        // expired files are gone first. Enumerates DB rows with a local mp3
        // (post age-pass, so already-cleared paths are excluded), stats each
        // file on disk, and asks the pure `MediaCapPolicy` which to evict
        // oldest-first until back under the cap. `capNearFull` is computed
        // BEFORE eviction so a warning fires even if eviction is disabled.
        if settings.mediaStorageCapEnabled {
            let remaining = (try? store.mp3sWithLocalFile()) ?? []
            var entries: [MediaCapPolicy.FileEntry] = []
            entries.reserveCapacity(remaining.count)
            for row in remaining {
                guard let attrs = try? fileManager.attributesOfItem(atPath: row.mp3Path) else { continue }
                let size = (attrs[.size] as? Int64) ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
                entries.append(MediaCapPolicy.FileEntry(guid: row.guid, path: row.mp3Path, sizeBytes: size, mtime: mtime))
            }
            let totalBytes = MediaCapPolicy.totalBytes(entries)
            // EFFECTIVE cap: the configured cap, clamped so it never exceeds 50%
            // of Vocateca-addressable disk (free + our current media). This is
            // the app-wide safety net so a huge configured cap (or a shrinking
            // disk) can never let Vocateca dominate the volume (2026-07-16).
            let capBytes = MediaCapPolicy.effectiveCapBytes(
                configuredGb: settings.mediaStorageCapGb,
                freeDiskBytes: DiskSpace.freeBytes(),
                currentMediaBytes: totalBytes)
            report.capUsedBytes = totalBytes
            report.capNearFull = MediaCapPolicy.isNearFull(entries: entries, capBytes: capBytes)

            let decision = MediaCapPolicy.decide(entries: entries, capBytes: capBytes)
            for entry in decision.toEvict {
                if fileManager.fileExists(atPath: entry.path) {
                    do { try fileManager.removeItem(atPath: entry.path) }
                    catch {
                        Log.debug("Maintenance: cap eviction delete failed", component: "Maintenance",
                                  context: [("path", entry.path), ("error", "\(error)")])
                        continue
                    }
                }
                try? store.clearMp3Path(guid: entry.guid)
                report.capEvictedCount += 1
                report.capFreedBytes += entry.sizeBytes
                Log.info("Retention: evicted media (storage cap)", component: "Maintenance",
                         context: [("guid", entry.guid), ("path", entry.path), ("sizeBytes", "\(entry.sizeBytes)")])
            }

            Log.info("Maintenance: storage-cap sweep", component: "Maintenance", context: [
                ("usedGb", String(format: "%.2f", Double(totalBytes) / 1_000_000_000)),
                ("capGb", "\(settings.mediaStorageCapGb)"),
                ("nearFull", "\(report.capNearFull)"),
                ("evicted", "\(report.capEvictedCount)"),
                ("freedGb", String(format: "%.2f", Double(report.capFreedBytes) / 1_000_000_000)),
            ])
        }

        // 2) Reclaim aged-out transcripts (opt-in, default disabled).
        let transcriptCandidates = (try? store.transcriptRetentionCandidates(
            days: settings.transcriptRetentionDays,
            nowISO: nowISO)) ?? []
        for c in transcriptCandidates {
            let mdPath = c.transcriptPath
            let base = (mdPath as NSString).deletingPathExtension
            let siblings = [mdPath, base + ".srt", base + ".txt", base + ".html"]
            for path in siblings where fileManager.fileExists(atPath: path) {
                do { try fileManager.removeItem(atPath: path) }
                catch {
                    Log.debug("Maintenance: transcript delete failed", component: "Maintenance",
                              context: [("path", path), ("error", "\(error)")])
                }
            }
            try? store.clearTranscriptPath(guid: c.guid)
            report.transcriptsDeleted += 1
            Log.info("Retention: reclaimed transcript", component: "Maintenance",
                     context: [("guid", c.guid)])
        }

        // 2b) „Zuletzt gelöscht" trash upkeep (combined danger model): purge
        // trashed transcripts/shows past the 30-day window, and finalize any
        // deferred media (mp3) whose undo window elapsed while the app was closed
        // (the app-quit-safe next-launch sweep — the toast handles the in-session
        // case). Age-based like retention above, so this runs every pass (not
        // one-time like the backfills). Best-effort; a failure never aborts the pass.
        let trash: TrashStore = {
            if let dir = trashDirOverride { return TrashStore(store: store, trashDir: dir, fileManager: fileManager) }
            return TrashStore.production(store: store)
        }()
        let mediaFinalized = (try? trash.finalizePendingMedia(nowISO: nowISO)) ?? 0
        let trashPurged = (try? trash.purge(olderThanDays: 30, nowISO: nowISO)) ?? 0
        report.trashPurged = trashPurged
        report.trashMediaFinalized = mediaFinalized

        // 3) Prune stale events.
        let cutoff = RetentionPolicy.eventCutoffISO(
            nowISO: nowISO, retentionDays: settings.eventRetentionDays)
        report.eventsPruned = (try? store.pruneEvents(olderThanISO: cutoff)) ?? 0

        // 4) Disk guard.
        report.freeBytes = Self.freeBytes(atPath: guardPath, fileManager: fileManager)
        report.shouldPauseForDisk = DiskGuard.shouldPause(
            freeBytes: report.freeBytes,
            minFreeGb: settings.diskGuardMinFreeGb,
            enabled: settings.diskGuardEnabled
        )

        Log.info("Maintenance pass complete", component: "Maintenance", context: [
            ("mp3sDeleted", "\(report.mp3sDeleted)"),
            ("mbReclaimed", "\(report.bytesReclaimed / 1_000_000)"),
            ("capEvicted", "\(report.capEvictedCount)"),
            ("capFreedMb", "\(report.capFreedBytes / 1_000_000)"),
            ("capNearFull", "\(report.capNearFull)"),
            ("transcriptsDeleted", "\(report.transcriptsDeleted)"),
            ("eventsPruned", "\(report.eventsPruned)"),
            ("trashPurged", "\(report.trashPurged)"),
            ("trashMediaFinalized", "\(report.trashMediaFinalized)"),
            ("freeGb", "\(report.freeBytes / 1_000_000_000)"),
            ("pauseForDisk", "\(report.shouldPauseForDisk)"),
        ])
        return report
    }

    /// The media directory downloaded audio is written under. Mirrors
    /// `URLSessionDownloader`'s default (`<userDataDir>/media`). Injectable for
    /// tests via `mediaDirOverride`.
    private var effectiveMediaDir: URL {
        mediaDirOverride ?? Paths.userDataDir().appendingPathComponent("media", isDirectory: true)
    }

    /// One-time sweep that records `mp3_path` for episodes whose downloaded file
    /// exists on disk but was never persisted (historic gap — the pipeline didn't
    /// write `mp3_path`). Idempotent via the `meta` guard flag; best-effort — a
    /// stat/DB error on one row never aborts the sweep or the maintenance pass.
    private func backfillMp3PathsOnce() {
        // Already done for this DB? (Skip the directory reconstruction entirely.)
        if let done = try? store.metaValue(Self.mp3BackfillDoneMetaKey), done == "1" {
            return
        }

        let mediaDir = effectiveMediaDir
        let missing = (try? store.episodesMissingMp3Path()) ?? []
        var matched = 0
        var unmatched = 0
        for row in missing {
            // Reconstruct the download path: <mediaDir>/<slugify(showSlug)>/<makeSlug(guid)>.mp3
            let showDir = mediaDir.appendingPathComponent(
                TextNormalization.slugify(row.showSlug), isDirectory: true)
            let fileURL = showDir.appendingPathComponent(
                "\(URLSessionDownloader.makeSlug(guid: row.guid)).mp3")
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try store.setMp3Path(guid: row.guid, path: fileURL.path)
                    matched += 1
                } catch {
                    Log.error("Maintenance: mp3 backfill write failed",
                              component: "Maintenance",
                              context: [("guid", row.guid), ("error", "\(error)")])
                }
            } else {
                unmatched += 1
            }
        }

        // Stamp the guard flag even when nothing matched — the sweep's job is done
        // and it must not re-scan the directory on every subsequent tick.
        try? store.setMeta(key: Self.mp3BackfillDoneMetaKey, value: "1")
        Log.info("Maintenance: one-time mp3_path backfill complete",
                 component: "Maintenance",
                 context: [("candidates", "\(missing.count)"),
                            ("matched", "\(matched)"), ("unmatched", "\(unmatched)")])
    }

    /// One-time sweep that indexes every on-disk transcript into `transcripts_fts`
    /// so the Library full-text search can find transcripts that finished before
    /// the FTS index existed. Idempotent via the `meta` guard flag AND via the
    /// upsert-by-guid in `indexTranscript` (a transcript already indexed by the
    /// pipeline write hook is simply re-written, never duplicated). Best-effort —
    /// a read/index error on one transcript never aborts the sweep or the pass.
    ///
    /// Resolves each transcript against the canonical output root (app data dir)
    /// AND the user-configured `settings.outputRoot`, mirroring the Library's own
    /// `TranscriptFileLoader.resolveWithRecovery` so a moved/re-pointed library
    /// still gets indexed.
    private func backfillTranscriptFTSOnce() {
        if let done = try? store.metaValue(Self.ftsBackfillDoneMetaKey), done == "1" {
            return
        }

        // Candidate roots: canonical (writer default) first, then the configured
        // output root if it differs.
        let canonical = Paths.userDataDir()
        let configured = URL(
            fileURLWithPath: (settings.outputRoot as NSString).expandingTildeInPath,
            isDirectory: true)
        var roots = [canonical]
        if configured.path != canonical.path { roots.append(configured) }

        let episodes = (try? store.allEpisodes()) ?? []
        var indexed = 0
        var skipped = 0
        for ep in episodes {
            guard let url = LibraryIndex.resolveTranscriptURL(for: ep, candidateRoots: roots)?.url,
                  let raw = try? String(contentsOf: url, encoding: .utf8) else {
                skipped += 1
                continue
            }
            // Prefer the SRT sibling's plain text (matches the rendered body);
            // fall back to stripping the markdown itself.
            let srtURL = url.deletingPathExtension().appendingPathExtension("srt")
            let plain: String
            if let srt = try? String(contentsOf: srtURL, encoding: .utf8), !srt.isEmpty {
                plain = TranscriptFormat.srtToPlainText(srt)
            } else {
                plain = TranscriptFormat.txtFromMarkdown(raw)
            }
            do {
                try store.indexTranscript(guid: ep.guid, showSlug: ep.showSlug,
                                          title: ep.title, content: plain)
                indexed += 1
            } catch {
                skipped += 1
                Log.error("Maintenance: transcript FTS backfill index failed",
                          component: "Maintenance",
                          context: [("guid", ep.guid), ("error", "\(error)")])
            }
        }

        // Stamp the guard even when nothing indexed — the sweep is done and must
        // not re-read the whole library on every subsequent tick.
        try? store.setMeta(key: Self.ftsBackfillDoneMetaKey, value: "1")
        Log.info("Maintenance: one-time transcript FTS backfill complete",
                 component: "Maintenance",
                 context: [("candidates", "\(episodes.count)"),
                            ("indexed", "\(indexed)"), ("skipped", "\(skipped)")])
    }

    /// Free bytes on the volume containing `path`. Delegates to the single
    /// implementation on ``DiskGuard`` (M12 hoisted it there so the queue worker's
    /// pre-claim check and this maintenance-tick check share one probe). Kept as a
    /// thin forwarder so existing call sites/tests referencing
    /// `MaintenanceRunner.freeBytes` stay valid.
    static func freeBytes(atPath path: String, fileManager: FileManager) -> Int64 {
        DiskGuard.freeBytes(atPath: path, fileManager: fileManager)
    }
}
