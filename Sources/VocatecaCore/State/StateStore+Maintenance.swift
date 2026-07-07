import Foundation
import GRDB

// MARK: - Maintenance / retention queries

/// A downloaded-mp3 row the retention pass may reclaim. The decision itself lives
/// in the pure ``RetentionPolicy``; this just surfaces the fields it needs.
public struct Mp3RetentionCandidate: Sendable, Equatable {
    public let guid: String
    public let showSlug: String
    public let status: String
    public let completedAt: String?
    public let mp3Path: String

    public init(guid: String, showSlug: String, status: String, completedAt: String?, mp3Path: String) {
        self.guid = guid
        self.showSlug = showSlug
        self.status = status
        self.completedAt = completedAt
        self.mp3Path = mp3Path
    }
}

public extension StateStore {

    /// Every episode whose local media is past its per-show effective retention
    /// cutoff. `overrideBySlug` maps show slug → `Show.mediaRetentionOverrideDays`;
    /// shows absent from the map follow the global policy. Keep-forever shows
    /// (effective `nil`) are excluded. Transcripts are never touched.
    func mp3RetentionCandidates(
        overrideBySlug: [String: Int],
        globalDays: Int,
        globalDeleteAfterTranscribe: Bool,
        nowISO: String
    ) throws -> [Mp3RetentionCandidate] {
        let all: [Mp3RetentionCandidate] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid, show_slug, status, completed_at, mp3_path
                FROM episodes
                WHERE mp3_path IS NOT NULL AND mp3_path <> ''
            """).map { row in
                Mp3RetentionCandidate(
                    guid: row["guid"], showSlug: row["show_slug"], status: row["status"],
                    completedAt: row["completed_at"], mp3Path: row["mp3_path"])
            }
        }
        return all.filter { cand in
            let override = overrideBySlug[cand.showSlug] ?? -1
            guard let days = RetentionPolicy.effectiveMediaRetentionDays(
                showOverride: override, globalDays: globalDays,
                globalDeleteAfterTranscribe: globalDeleteAfterTranscribe)
            else { return false }   // keep forever
            return RetentionPolicy.shouldDeleteMp3(
                status: cand.status, completedAtISO: cand.completedAt, hasLocalFile: true,
                deleteAfterTranscribe: days == 0, retentionDays: days, nowISO: nowISO)
        }
    }

    /// Records the on-disk path of an episode's downloaded media file.
    ///
    /// **Load-bearing for media retention.** The retention passes
    /// (`mp3RetentionCandidates`, `mp3sWithLocalFile`) select rows
    /// `WHERE mp3_path IS NOT NULL`; if no production path ever writes it, the
    /// 7-day age-out, per-show overrides, storage cap, and "storage almost full"
    /// warning are all dead paths and the media directory grows unbounded. The
    /// pipeline calls this at the `.downloaded` transition so every downloaded
    /// file is retention-eligible. Parameterised UPDATE — never string-interpolated.
    func setMp3Path(guid: String, path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET mp3_path = ? WHERE guid = ?",
                arguments: [path, guid]
            )
        }
    }

    /// Clears the recorded `mp3_path` for an episode (called after the file has
    /// been deleted from disk, so the pipeline never treats a reclaimed file as
    /// present).
    func clearMp3Path(guid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET mp3_path = NULL WHERE guid = ?",
                arguments: [guid]
            )
        }
    }

    /// Overwrites an episode's stored title. Used by the one-off metadata
    /// backfill (N5): a pre-fix one-off import persisted the raw pasted URL as
    /// its title; once the yt-dlp download has fetched fresh metadata we replace
    /// it with the real video title. Public (unlike the retention helpers) so
    /// `QueueController`'s download-metadata callback can call it. No-op for a
    /// blank title; parameterised UPDATE.
    public func updateEpisodeTitle(guid: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET title = ? WHERE guid = ?",
                arguments: [trimmed, guid]
            )
        }
    }

    /// Every episode whose transcript is past the global `transcriptRetentionDays`
    /// cutoff. `days <= 0` disables the pass (keep forever) and returns `[]`.
    /// Mirrors `mp3RetentionCandidates`'s query shape; the age math is delegated
    /// to `RetentionPolicy.eventCutoffISO` (reused here for the "N days ago"
    /// cutoff, not just event pruning).
    func transcriptRetentionCandidates(
        days: Int,
        nowISO: String
    ) throws -> [(guid: String, transcriptPath: String)] {
        guard days > 0 else { return [] }
        guard let cutoff = RetentionPolicy.eventCutoffISO(nowISO: nowISO, retentionDays: days) else {
            return []
        }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid, transcript_path
                FROM episodes
                WHERE transcript_path IS NOT NULL AND transcript_path <> ''
                  AND completed_at IS NOT NULL AND completed_at < ?
            """, arguments: [cutoff]).map { row in
                (guid: row["guid"] as String, transcriptPath: row["transcript_path"] as String)
            }
        }
    }

    /// Clears the recorded `transcript_path` for an episode (called after the
    /// transcript files have been deleted from disk).
    func clearTranscriptPath(guid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET transcript_path = NULL WHERE guid = ?",
                arguments: [guid]
            )
        }
    }

    /// Every episode that currently has a local mp3 on disk (`mp3_path` set),
    /// regardless of retention policy — the raw universe the storage-cap pass
    /// enumerates before asking `MediaCapPolicy` which ones to evict. Driving
    /// off DB rows (rather than walking the media directory) keeps eviction in
    /// sync with state, mirroring how the age pass selects its candidates.
    func mp3sWithLocalFile() throws -> [(guid: String, mp3Path: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid, mp3_path
                FROM episodes
                WHERE mp3_path IS NOT NULL AND mp3_path <> ''
            """).map { row in
                (guid: row["guid"] as String, mp3Path: row["mp3_path"] as String)
            }
        }
    }

    /// Episodes that have NO recorded `mp3_path` yet — the universe the one-time
    /// media backfill sweep reconstructs a path for. Restricted to statuses where
    /// a downloaded file plausibly still exists on disk (`downloaded`,
    /// `transcribing`, `done`), so we don't stat files for pending/failed/skipped
    /// rows that never downloaded. Returns `(guid, showSlug)` — the caller rebuilds
    /// the expected `<mediaDir>/<slug>/<guidSlug>.mp3` path and stats it.
    func episodesMissingMp3Path() throws -> [(guid: String, showSlug: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid, show_slug
                FROM episodes
                WHERE (mp3_path IS NULL OR mp3_path = '')
                  AND status IN ('downloaded', 'transcribing', 'done')
            """).map { row in
                (guid: row["guid"] as String, showSlug: row["show_slug"] as String)
            }
        }
    }

    /// Deletes `events` rows older than the ISO `cutoff`. Returns the number of
    /// rows removed. A `nil`/empty cutoff prunes nothing (retention disabled).
    @discardableResult
    func pruneEvents(olderThanISO cutoff: String?) throws -> Int {
        guard let cutoff, !cutoff.isEmpty else { return 0 }
        return try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM events WHERE ts < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }
}
