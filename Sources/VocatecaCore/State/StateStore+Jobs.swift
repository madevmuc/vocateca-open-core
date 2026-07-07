import Foundation
import GRDB

// MARK: - Job ownership (heartbeat) primitives on StateStore
//
// H7 — App + CLI parallel reclaim.
//
// Both the app (`QueueController` drain) and `vocateca-cli queue run` drive the
// SAME state database. On launch the app resets every `downloading`/`transcribing`
// row back to `pending` (`reclaimOrphanedInFlight`), assuming a fresh process has
// nothing genuinely in-flight. That assumption is FALSE when a CLI drain is
// running concurrently: the app's launch-reclaim yanks the CLI's live episode
// back to `pending`, both processes then claim + transcribe it, and both write
// the same `<slug>.mp3.part` — double work + a corrupt download.
//
// Fix: a lightweight ownership ledger in the existing-but-unused `jobs` table.
// When a process starts real work on an episode it opens a job row carrying its
// PID + a `started_at` heartbeat; the pipeline refreshes the heartbeat across a
// long transcribe and closes the row at a terminal status. Reclaim then becomes
// *guarded*: a row whose owning PID is still alive AND whose heartbeat is fresh
// is left alone (a live sibling process owns it); only genuinely orphaned rows
// (dead PID or stale heartbeat) are reclaimed as before. This runs in the shared
// `Pipeline`, so the app drain and the CLI drain register ownership identically.
//
// The single-claim atomicity (`claimNextPending`'s `UPDATE…RETURNING` in a write
// TX) and wave-1's attempts-bump-on-reclaim are untouched — jobs are a *separate*
// advisory ledger consulted only by the guarded reclaim.

extension StateStore {

    /// The `jobs.kind` value used for a pipeline episode-processing claim.
    public static let pipelineJobKind = "pipeline"

    /// Default staleness window (seconds) for a job heartbeat. A job whose
    /// `started_at` is older than this — even if its PID is somehow still alive —
    /// is treated as orphaned and eligible for reclaim, so a wedged process can
    /// never pin an episode forever. 10 minutes comfortably exceeds the heartbeat
    /// refresh interval (see `Pipeline` — refreshed at each phase boundary and on
    /// a periodic tick during a long transcribe).
    public static let defaultJobStaleSeconds: TimeInterval = 600

    // MARK: - Open / refresh / close

    /// Opens (or refreshes) a job row asserting that PID `pid` is actively
    /// processing `guid`. Idempotent per (guid, pid): a second call for a still-open
    /// row just bumps the `started_at` heartbeat rather than inserting a duplicate.
    ///
    /// Any *other* process's stale/dead open row for the same guid is closed first
    /// (marked ended) so exactly one live owner is recorded — this is the takeover
    /// path after a legitimate reclaim.
    public func beginJob(guid: String, pid: Int32, kind: String = pipelineJobKind) throws {
        let now = Event.nowISO()
        try dbQueue.write { db in
            // Refresh an existing open row for THIS pid+guid (heartbeat), else insert.
            try db.execute(
                sql: """
                    UPDATE jobs SET started_at = ?
                    WHERE guid = ? AND pid = ? AND ended_at IS NULL
                """,
                arguments: [now, guid, Int(pid)])
            if db.changesCount == 0 {
                // Close any other process's dangling open row for this guid so the
                // ledger has a single live owner (defensive; reclaim usually did this).
                try db.execute(
                    sql: "UPDATE jobs SET ended_at = ? WHERE guid = ? AND ended_at IS NULL",
                    arguments: [now, guid])
                try db.execute(
                    sql: """
                        INSERT INTO jobs (kind, guid, pid, started_at)
                        VALUES (?, ?, ?, ?)
                    """,
                    arguments: [kind, guid, Int(pid), now])
            }
        }
    }

    /// Refreshes the heartbeat (`started_at`) of THIS process's open job row for
    /// `guid`. Cheap — used from the pipeline's long transcribe to keep the row
    /// fresh so a concurrent reclaim never mistakes a slow-but-alive job for an
    /// orphan. No-op (no throw) if the row was already closed.
    public func heartbeatJob(guid: String, pid: Int32) throws {
        let now = Event.nowISO()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE jobs SET started_at = ?
                    WHERE guid = ? AND pid = ? AND ended_at IS NULL
                """,
                arguments: [now, guid, Int(pid)])
        }
    }

    /// Closes THIS process's open job row(s) for `guid` (sets `ended_at`). Called
    /// at every terminal pipeline outcome (done / failed / skipped / requeued) so
    /// the ledger doesn't accumulate stale open rows and a future reclaim sees the
    /// episode as un-owned. `errorText` is optional diagnostics.
    public func endJob(guid: String, pid: Int32, errorText: String? = nil) throws {
        let now = Event.nowISO()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE jobs SET ended_at = ?, error_text = COALESCE(?, error_text)
                    WHERE guid = ? AND pid = ? AND ended_at IS NULL
                """,
                arguments: [now, errorText, guid, Int(pid)])
        }
    }

    // MARK: - Ownership query

    /// A live-owner snapshot for one in-flight episode: the PID that most recently
    /// opened an *open* job row for it and that row's heartbeat.
    struct JobOwner {
        let pid: Int32
        let startedAt: String
    }

    /// Returns the current open-job owner for `guid`, or `nil` when no job row is
    /// open (episode is un-owned → freely reclaimable). Reads the most recent open
    /// row (highest `id`) so a takeover row wins over an older dangling one.
    func openJobOwner(_ db: Database, guid: String) throws -> JobOwner? {
        let row = try Row.fetchOne(db, sql: """
            SELECT pid, started_at FROM jobs
            WHERE guid = ? AND ended_at IS NULL AND pid IS NOT NULL
            ORDER BY id DESC LIMIT 1
        """, arguments: [guid])
        guard let row, let pid: Int64 = row["pid"] else { return nil }
        let startedAt: String = row["started_at"] ?? ""
        return JobOwner(pid: Int32(truncatingIfNeeded: pid), startedAt: startedAt)
    }

    /// Whether an in-flight episode is currently owned by a *live* sibling process
    /// and therefore must NOT be reclaimed. True iff there is an open job row whose
    /// PID is a different, still-running process AND whose heartbeat is fresh
    /// (within `staleSeconds`). The current process (`selfPID`) is never treated as
    /// a live owner — its own leftover rows are from a previous, now-dead run.
    func isOwnedByLiveProcess(
        _ db: Database,
        guid: String,
        selfPID: Int32,
        now: Date,
        staleSeconds: TimeInterval,
        isAlive: (Int32) -> Bool
    ) throws -> Bool {
        guard let owner = try openJobOwner(db, guid: guid) else { return false }
        // Our own PID re-appearing means a stale row from a prior process that
        // happened to be reassigned the same PID — not a live sibling. Reclaim.
        if owner.pid == selfPID { return false }
        guard isAlive(owner.pid) else { return false }          // dead PID → orphan
        // Use the strict (optional) parser, NOT Event.date(fromISO:) — the latter
        // falls back to `now` on a bad timestamp, which would read as "fresh" and
        // pin the episode forever. An unparseable heartbeat must count as stale.
        guard let started = FeedBackoff.parseISO8601(owner.startedAt) else { return false }
        let age = now.timeIntervalSince(started)
        return age >= 0 && age < staleSeconds                    // fresh heartbeat → live
    }
}

// MARK: - Live-process probe

/// Whether `pid` names a process this user can signal (i.e. it is alive).
/// `kill(pid, 0)` performs the permission + existence check without sending a
/// signal: 0 → alive; `ESRCH` → no such process; `EPERM` → alive but owned by
/// another user (still "alive" for our purposes). Used by the guarded reclaim to
/// distinguish a crashed owner (reclaim) from a live sibling (leave alone).
public func processIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}
