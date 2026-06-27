"""SQLite state store for episodes/jobs/meta."""

from __future__ import annotations

import hashlib
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterator, Optional

from core import events


class EpisodeStatus(str, Enum):
    PENDING = "pending"
    DOWNLOADING = "downloading"
    DOWNLOADED = "downloaded"
    TRANSCRIBING = "transcribing"
    DONE = "done"
    FAILED = "failed"
    STALE = "stale"
    # Deliberately not processed (e.g. a Short on a show that excludes
    # Shorts); leaves the pending pool but is not a failure.
    SKIPPED = "skipped"
    # Temporarily not processable, re-checked later (e.g. a live/premiere
    # video that hasn't finished); leaves the pending pool but is not a failure.
    DEFERRED = "deferred"
    # Manually deactivated by the user: stays visible in the queue but the
    # worker never claims it (the claim query is status='pending'). Toggle back
    # to pending to resume; the feed poll preserves it (upsert keeps status).
    PAUSED = "paused"


# Queue claim ordering (2.5). Whitelisted SQL fragments — never interpolate a
# raw setting value. `priority DESC` always leads so 'Run next/now' bumps win.
_QUEUE_ORDERS = {
    "oldest_first": "priority DESC, pub_date ASC",
    "newest_first": "priority DESC, pub_date DESC",
    "shortest_first": "priority DESC, (duration_sec IS NULL), duration_sec ASC",
}


def claim_order_by(queue_order: str) -> str:
    """Return the whitelisted ORDER BY fragment for a queue_order setting.

    Falls back to ``oldest_first`` for any unknown value.
    """
    return _QUEUE_ORDERS.get(queue_order, _QUEUE_ORDERS["oldest_first"])


# Episode status → lifecycle event type. Statuses absent from this map
# (PENDING/STALE/PAUSED) emit no event.
_STATUS_EVENT_MAP = {
    EpisodeStatus.DOWNLOADING: events.EventType.EPISODE_DOWNLOAD_STARTED,
    EpisodeStatus.DOWNLOADED: events.EventType.EPISODE_DOWNLOADED,
    EpisodeStatus.TRANSCRIBING: events.EventType.EPISODE_TRANSCRIBE_STARTED,
    EpisodeStatus.DONE: events.EventType.EPISODE_TRANSCRIBED,
    EpisodeStatus.FAILED: events.EventType.EPISODE_FAILED,
    EpisodeStatus.SKIPPED: events.EventType.EPISODE_SKIPPED,
    EpisodeStatus.DEFERRED: events.EventType.EPISODE_DEFERRED,
}


_SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    guid TEXT PRIMARY KEY,
    show_slug TEXT NOT NULL,
    title TEXT NOT NULL,
    pub_date TEXT NOT NULL,
    mp3_url TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    mp3_path TEXT,
    transcript_path TEXT,
    attempted_at TEXT,
    completed_at TEXT,
    error_text TEXT
);
CREATE INDEX IF NOT EXISTS idx_episodes_show ON episodes(show_slug);
CREATE INDEX IF NOT EXISTS idx_episodes_status ON episodes(status);

CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    show_slug TEXT,
    guid TEXT,
    pid INTEGER,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    error_text TEXT
);

CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Per-guid claim on a filesystem slug. The slug IS an episode's on-disk
-- identity (`<slug>.mp3` / `<slug>.md`), but build_slug (date + ep-num +
-- title) is NOT unique: feed re-uploads and '(1/2)'/'(2/2)' parts collapse
-- to the same slug, so two episodes would share one audio file and one
-- transcript. The PRIMARY KEY on slug serialises concurrent claims; the
-- UNIQUE on guid keeps reservation idempotent. See StateStore.reserve_slug.
CREATE TABLE IF NOT EXISTS slug_reservations (
    slug TEXT PRIMARY KEY,
    guid TEXT NOT NULL UNIQUE
);

-- Append-only lifecycle event log (core.events backbone). Pruned on startup
-- to settings.event_retention_days. Backs timeline / filterable logs / stats.
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    type TEXT NOT NULL,
    show_slug TEXT,
    guid TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_guid ON events(guid);
"""


class StateStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        # Thread-local persistent connection cache. Opening + closing a
        # SQLite connection on every _conn() call dominated wall time on
        # poll-heavy paths (QueueTab refresh, worker DB-claim loop). We
        # keep one connection per thread for the app's lifetime; it gets
        # GC'd when the thread exits.
        self._tls = threading.local()

    @contextmanager
    def _conn(self) -> Iterator[sqlite3.Connection]:
        c = getattr(self._tls, "conn", None)
        if c is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            # check_same_thread=False is safe because each thread has its
            # OWN connection (TLS); we never share a connection across
            # threads. busy_timeout lets concurrent writers wait briefly
            # instead of failing immediately on writer-lock contention.
            c = sqlite3.connect(self.path, check_same_thread=False, timeout=30.0)
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA synchronous=NORMAL")
            c.execute("PRAGMA busy_timeout=30000")
            self._tls.conn = c
        try:
            yield c
            c.commit()
        except Exception:
            try:
                c.rollback()
            except Exception:
                pass
            raise

    def init_schema(self) -> None:
        with self._conn() as c:
            # WAL mode lets watchdog, worker thread, and UI refresh all
            # read/write concurrently without file-level locking.
            try:
                c.execute("PRAGMA journal_mode=WAL")
            except Exception:
                pass  # some filesystems don't support WAL — fall back
            c.executescript(_SCHEMA)
            # Idempotent column additions (ignore if they already exist).
            for stmt in (
                "ALTER TABLE episodes ADD COLUMN duration_sec INTEGER",
                "ALTER TABLE episodes ADD COLUMN word_count INTEGER",
                "ALTER TABLE episodes ADD COLUMN priority INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE episodes ADD COLUMN detected_language TEXT",
                "ALTER TABLE episodes ADD COLUMN mean_confidence REAL",
                "ALTER TABLE episodes ADD COLUMN error_category TEXT",
                "ALTER TABLE episodes ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0",
            ):
                try:
                    c.execute(stmt)
                except Exception:
                    pass
            # Composite index for the DB-claim query in the worker
            # (`SELECT … WHERE status='pending' ORDER BY priority DESC,
            # pub_date ASC LIMIT 1`). Created AFTER the priority ALTER
            # so a fresh DB has the column available before index build.
            try:
                c.execute(
                    "CREATE INDEX IF NOT EXISTS idx_episodes_claim "
                    "ON episodes(status, priority DESC, pub_date)"
                )
            except Exception:
                pass

    def upsert_episode(
        self,
        *,
        show_slug: str,
        guid: str,
        title: str,
        pub_date: str,
        mp3_url: str,
        duration_sec: int | None = None,
    ) -> None:
        with self._conn() as c:
            c.execute(
                """
                INSERT INTO episodes (guid, show_slug, title, pub_date, mp3_url,
                                       status, duration_sec)
                VALUES (?, ?, ?, ?, ?, 'pending', ?)
                ON CONFLICT(guid) DO UPDATE SET
                    title=excluded.title,
                    pub_date=excluded.pub_date,
                    mp3_url=excluded.mp3_url,
                    duration_sec=COALESCE(excluded.duration_sec, episodes.duration_sec)
            """,
                (guid, show_slug, title, pub_date, mp3_url, duration_sec),
            )

    def record_completion(
        self, guid: str, word_count: int, duration_sec: int | None = None
    ) -> None:
        with self._conn() as c:
            if duration_sec is not None:
                c.execute(
                    "UPDATE episodes SET word_count=?, duration_sec=? WHERE guid=?",
                    (word_count, duration_sec, guid),
                )
            else:
                c.execute("UPDATE episodes SET word_count=? WHERE guid=?", (word_count, guid))

    def set_detected_language(self, guid: str, lang: str) -> None:
        """Persist the language whisper auto-detected for this episode (1.1)."""
        with self._conn() as c:
            c.execute("UPDATE episodes SET detected_language=? WHERE guid=?", (lang, guid))

    def set_mean_confidence(self, guid: str, value: float) -> None:
        """Persist the mean whisper confidence for this episode (1.3)."""
        with self._conn() as c:
            c.execute("UPDATE episodes SET mean_confidence=? WHERE guid=?", (value, guid))

    def set_error_details(self, guid: str, category: str, attempts: int, error_text: str) -> None:
        """Terminal failure with an explicit attempt count (6.1 in-loop retry):
        set status FAILED + error_text + error_category + attempts, and emit the
        episode.failed event."""
        with self._conn() as c:
            c.execute(
                "UPDATE episodes SET error_category=?, attempts=? WHERE guid=?",
                (category, int(attempts), guid),
            )
        self.set_status(guid, EpisodeStatus.FAILED, error_text=error_text)

    def record_failure(self, guid: str, category: str, error_text: str, *, retry: bool) -> int:
        """Record a failure (6.1): bump ``attempts``, store ``error_category``,
        and set status to PENDING (when ``retry``) or FAILED. Returns the new
        attempt count. Emits the matching lifecycle event via set_status."""
        with self._conn() as c:
            cur = c.execute(
                "UPDATE episodes SET attempts = COALESCE(attempts, 0) + 1, error_category=? "
                "WHERE guid=?",
                (category, guid),
            )
            if cur.rowcount:
                row = c.execute("SELECT attempts FROM episodes WHERE guid=?", (guid,)).fetchone()
                attempts = row["attempts"] if row else 1
            else:
                attempts = 1
        if retry:
            self.set_status(guid, EpisodeStatus.PENDING)
        else:
            self.set_status(guid, EpisodeStatus.FAILED, error_text=error_text)
        return attempts

    def set_duration_sec(self, guid: str, duration_sec: int) -> None:
        """Persist a video's known audio length mid-flight (before transcription
        completes) so the Queue's Audio / Whisper / Finish columns + the live
        transcribe % have a real audio length to work from."""
        with self._conn() as c:
            c.execute(
                "UPDATE episodes SET duration_sec=? WHERE guid=?",
                (duration_sec, guid),
            )

    def get_episode(self, guid: str) -> Optional[Dict[str, Any]]:
        with self._conn() as c:
            row = c.execute("SELECT * FROM episodes WHERE guid = ?", (guid,)).fetchone()
            return dict(row) if row else None

    def list_by_status(self, show_slug: str, status: EpisodeStatus) -> list[Dict[str, Any]]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM episodes WHERE show_slug=? AND status=? "
                "ORDER BY priority DESC, pub_date",
                (show_slug, status.value),
            ).fetchall()
            return [dict(r) for r in rows]

    def claim_one_pending(self, scope_slugs: list[str], order_by: str) -> Optional[dict]:
        """Atomically claim the next pending episode for one of ``scope_slugs``,
        flipping it to ``downloading``, and return its row (or None).

        ``order_by`` MUST be a whitelisted fragment from ``claim_order_by`` —
        never raw user input. The single ``UPDATE … RETURNING`` is atomic, so
        concurrent download workers can call this without double-claiming a row
        (parallel transcription, 2.2)."""
        if not scope_slugs:
            return None
        placeholders = ",".join("?" for _ in scope_slugs)
        with self._conn() as c:
            row = c.execute(
                "UPDATE episodes SET status='downloading' "
                "WHERE guid = ("
                "  SELECT guid FROM episodes "
                f"  WHERE status='pending' AND show_slug IN ({placeholders}) "
                f"  ORDER BY {order_by} LIMIT 1"
                ") RETURNING *",
                tuple(scope_slugs),
            ).fetchone()
        return dict(row) if row is not None else None

    def set_priority(self, guid: str, priority: int) -> None:
        with self._conn() as c:
            c.execute("UPDATE episodes SET priority=? WHERE guid=?", (priority, guid))

    # Base for manual "move to top" ordering — above the Run-now (10) /
    # Run-next (5) bump priorities so a move-to-top episode genuinely lands
    # at the top of the claim order (priority DESC).
    _MANUAL_TOP_BASE = 1000

    def set_priorities(self, ordered_guids: list[str]) -> None:
        """Persist a user-chosen ordering (2.1): the first guid gets the highest
        priority so the claim ORDER BY (priority DESC, …) yields the same order.
        Priorities start above the Run-now/Run-next bumps so 'move to top' really
        reaches the top. Guids not listed keep their existing priority."""
        n = len(ordered_guids)
        with self._conn() as c:
            for i, guid in enumerate(ordered_guids):
                c.execute(
                    "UPDATE episodes SET priority=? WHERE guid=?",
                    (self._MANUAL_TOP_BASE + (n - i), guid),
                )

    def move_to_bottom(self, guids: list[str]) -> None:
        """Sink ``guids`` below everything else in the claim order (2.1)."""
        with self._conn() as c:
            for guid in guids:
                c.execute(
                    "UPDATE episodes SET priority=? WHERE guid=?",
                    (-self._MANUAL_TOP_BASE, guid),
                )

    def delete_episodes_for_show(self, show_slug: str) -> int:
        """Purge all episode rows for a show (used when the show is removed) so
        re-adding the same channel starts from a clean slate instead of finding
        its old episodes still marked ``done`` (and thus never re-queued). Also
        drops the show's slug reservations. Transcripts on disk are untouched.
        Returns the number of episode rows deleted."""
        with self._conn() as c:
            guids = [
                r["guid"]
                for r in c.execute(
                    "SELECT guid FROM episodes WHERE show_slug=?", (show_slug,)
                ).fetchall()
            ]
            cur = c.execute("DELETE FROM episodes WHERE show_slug=?", (show_slug,))
            if guids:
                ph = ",".join("?" for _ in guids)
                c.execute(f"DELETE FROM slug_reservations WHERE guid IN ({ph})", tuple(guids))
            return cur.rowcount or 0

    def set_mp3_path(self, guid: str, mp3_path: str) -> None:
        """Persist the actual on-disk MP3 path so the orphan-recovery
        path (next launch after a crash between download and transcribe)
        can find the file even when the slug-derived path differs from
        what was actually written. Pre-2026-04-23 this was reconstructed
        from (pub_date, title, episode_number) on every transcribe call;
        when the in-memory ep_num_map didn't carry the episode_number
        for orphans, the rebuild defaulted to '0000' and missed the
        real file (saved with the genuine episode number)."""
        with self._conn() as c:
            c.execute("UPDATE episodes SET mp3_path=? WHERE guid=?", (mp3_path, guid))

    def reserve_slug(self, guid: str, base_slug: str) -> str:
        """Return a slug for ``guid`` that is unique across all episodes.

        An episode's on-disk identity (its ``<slug>.mp3`` and ``<slug>.md``)
        is the slug, but :func:`core.pipeline.build_slug` is not unique —
        two episodes with the same publish date + title (feed re-uploads,
        or ``(1/2)`` vs ``(2/2)`` parts) collapse to one slug and would
        share one audio file and one transcript. Under parallel
        transcription the first to finish unlinks the shared mp3
        (retention) and the second fails whisper-cli with ``exit 2`` ("no
        input files"); pairs that both "succeed" silently overwrite each
        other's transcript.

        This claims ``base_slug`` via the slug PRIMARY KEY. If another guid
        already owns it, a short deterministic guid fingerprint is appended
        (``<base>-<hash8>``) so the slug stays human-readable and stable
        across runs. Idempotent: a guid that already holds a reservation
        keeps it.
        """
        digest = hashlib.sha1(guid.encode("utf-8")).hexdigest()
        with self._conn() as c:
            row = c.execute("SELECT slug FROM slug_reservations WHERE guid=?", (guid,)).fetchone()
            if row is not None:
                return row["slug"]
            # Try the clean slug, then a short-hash-suffixed one. A failed
            # INSERT (slug already owned by another guid) is a statement-
            # level error in SQLite — the transaction stays usable, so we
            # just move to the next candidate.
            for cand in (base_slug, f"{base_slug}-{digest[:8]}"):
                try:
                    c.execute(
                        "INSERT INTO slug_reservations (slug, guid) VALUES (?, ?)",
                        (cand, guid),
                    )
                    return cand
                except sqlite3.IntegrityError:
                    continue
            # Both taken by other guids (would need a sha1-prefix collision).
            # Fall back to the full digest to guarantee uniqueness.
            cand = f"{base_slug}-{digest}"
            c.execute("INSERT INTO slug_reservations (slug, guid) VALUES (?, ?)", (cand, guid))
            return cand

    def other_active_uses_mp3_path(self, guid: str, mp3_path: str) -> bool:
        """True if some OTHER episode still needs this exact audio file
        (status not yet done/failed). Guards the post-transcribe retention
        unlink so a finishing episode never deletes a file a concurrent
        duplicate still points at. With unique slugs this is belt-and-
        suspenders, but it also protects legacy rows written before
        reservation existed."""
        with self._conn() as c:
            row = c.execute(
                "SELECT 1 FROM episodes WHERE mp3_path=? AND guid!=? "
                "AND status IN ('pending','downloading','downloaded','transcribing') "
                "LIMIT 1",
                (mp3_path, guid),
            ).fetchone()
            return row is not None

    def set_status(
        self, guid: str, status: EpisodeStatus, *, error_text: Optional[str] = None
    ) -> None:
        now = datetime.now(timezone.utc).isoformat()
        emits_event = _STATUS_EVENT_MAP.get(status) is not None
        with self._conn() as c:
            if status == EpisodeStatus.DONE:
                # Success clears the failure bookkeeping so a later, unrelated
                # transient failure gets its full retry budget (6.1).
                c.execute(
                    "UPDATE episodes SET status=?, completed_at=?, error_text=NULL, "
                    "error_category=NULL, attempts=0 WHERE guid=?",
                    (status.value, now, guid),
                )
            elif status in (EpisodeStatus.DOWNLOADING, EpisodeStatus.TRANSCRIBING):
                c.execute(
                    "UPDATE episodes SET status=?, attempted_at=? WHERE guid=?",
                    (status.value, now, guid),
                )
            elif status == EpisodeStatus.FAILED:
                c.execute(
                    "UPDATE episodes SET status=?, error_text=? WHERE guid=?",
                    (status.value, error_text, guid),
                )
            else:
                c.execute("UPDATE episodes SET status=? WHERE guid=?", (status.value, guid))
            # Only fetch the payload row for statuses that actually emit an event
            # — PENDING/STALE/PAUSED transitions (common in the worker hot path)
            # skip the extra SELECT entirely.
            row = (
                c.execute(
                    "SELECT show_slug, title, detected_language FROM episodes WHERE guid=?",
                    (guid,),
                ).fetchone()
                if emits_event
                else None
            )
        if emits_event:
            self._emit_status_event(guid, status, row, error_text)

    @staticmethod
    def _emit_status_event(guid, status, row, error_text):
        """Translate a status change into a lifecycle event (best-effort)."""
        event_type = _STATUS_EVENT_MAP.get(status)
        if event_type is None:
            return
        payload: dict = {}
        if row is not None and row["title"]:
            payload["title"] = row["title"]
        if status == EpisodeStatus.DONE and row is not None and row["detected_language"]:
            payload["detected_language"] = row["detected_language"]
        if error_text:
            payload["error_text"] = error_text
        events.emit(
            events.Event(
                type=event_type,
                ts=events.now_iso(),
                show_slug=(row["show_slug"] if row is not None else None),
                guid=guid,
                payload=payload,
            )
        )

    def recover_in_flight(self) -> int:
        """Called on startup: reset downloading/transcribing → pending."""
        with self._conn() as c:
            cur = c.execute(
                "UPDATE episodes SET status='pending' "
                "WHERE status IN ('downloading', 'transcribing')"
            )
            return cur.rowcount

    def clear_pending(self) -> int:
        """Empty the queue: mark every pending / downloading / downloaded
        / transcribing episode as ``done`` so the worker stops picking
        them up. Used by the Queue tab's 'Remove all items' button.
        Returns the number of rows touched.
        """
        with self._conn() as c:
            cur = c.execute(
                "UPDATE episodes SET status='done', priority=0 "
                "WHERE status IN ('pending','downloading','downloaded','transcribing')"
            )
            return cur.rowcount or 0

    def snapshot_statuses(self, statuses: list[str]) -> list[tuple[str, str, int]]:
        """Capture (guid, status, priority) for rows in the given statuses, so a
        destructive bulk change (e.g. clear-queue) can be undone (9.5)."""
        ph = ",".join("?" for _ in statuses)
        with self._conn() as c:
            rows = c.execute(
                f"SELECT guid, status, priority FROM episodes WHERE status IN ({ph})",
                tuple(statuses),
            ).fetchall()
        return [(r["guid"], r["status"], r["priority"]) for r in rows]

    def restore_statuses(self, snapshot: list[tuple[str, str, int]]) -> int:
        """Restore (guid, status, priority) rows captured by ``snapshot_statuses``."""
        with self._conn() as c:
            for guid, status, priority in snapshot:
                c.execute(
                    "UPDATE episodes SET status=?, priority=? WHERE guid=?",
                    (status, priority, guid),
                )
        return len(snapshot)

    def set_meta(self, key: str, value: str) -> None:
        with self._conn() as c:
            c.execute(
                """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
                (key, value),
            )

    def get_meta(self, key: str) -> Optional[str]:
        with self._conn() as c:
            row = c.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
            return row["value"] if row else None

    # ── events (core.events persistence) ──────────────────────────────────
    def append_event(self, ev: Any) -> None:
        """Persist a single ``core.events.Event``."""
        import json

        with self._conn() as c:
            c.execute(
                "INSERT INTO events (ts, type, show_slug, guid, payload_json) "
                "VALUES (?, ?, ?, ?, ?)",
                (
                    ev.ts,
                    ev.type,
                    ev.show_slug,
                    ev.guid,
                    json.dumps(ev.payload or {}, ensure_ascii=False),
                ),
            )

    def query_events(
        self,
        *,
        type_prefix: Optional[str] = None,
        show_slug: Optional[str] = None,
        guid: Optional[str] = None,
        since: Optional[str] = None,
        limit: int = 1000,
    ) -> list[dict]:
        """Read persisted events, oldest-first, with optional filters.

        ``type_prefix`` matches by prefix (e.g. ``"episode."``) or, with no
        trailing dot, exactly. ``since`` is an inclusive ISO-8601 lower bound on
        ``ts`` (string comparison is valid for ISO-8601 UTC).
        """
        import json

        clauses: list[str] = []
        params: list[Any] = []
        if type_prefix:
            if type_prefix.endswith("."):
                clauses.append("type LIKE ?")
                params.append(type_prefix + "%")
            else:
                clauses.append("type = ?")
                params.append(type_prefix)
        if show_slug is not None:
            clauses.append("show_slug = ?")
            params.append(show_slug)
        if guid is not None:
            clauses.append("guid = ?")
            params.append(guid)
        if since is not None:
            clauses.append("ts >= ?")
            params.append(since)
        where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        params.append(int(limit))
        with self._conn() as c:
            rows = c.execute(
                f"SELECT id, ts, type, show_slug, guid, payload_json FROM events"
                f"{where} ORDER BY id ASC LIMIT ?",
                params,
            ).fetchall()
        out: list[dict] = []
        for r in rows:
            d = dict(r)
            try:
                d["payload"] = json.loads(d.pop("payload_json") or "{}")
            except Exception:
                d["payload"] = {}
                d.pop("payload_json", None)
            out.append(d)
        return out

    def count_events(self, *, type_exact: Optional[str] = None, since: Optional[str] = None) -> int:
        """Cheap COUNT(*) over the events table with optional type/since filters
        (avoids materialising rows just to count them)."""
        clauses: list[str] = []
        params: list[Any] = []
        if type_exact is not None:
            clauses.append("type = ?")
            params.append(type_exact)
        if since is not None:
            clauses.append("ts >= ?")
            params.append(since)
        where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        with self._conn() as c:
            row = c.execute(f"SELECT COUNT(*) AS n FROM events{where}", params).fetchone()
        return int(row["n"]) if row else 0

    def prune_events(self, retention_days: int) -> int:
        """Delete events older than ``retention_days``. Returns rows deleted.

        A non-positive ``retention_days`` keeps everything (no-op).
        """
        if retention_days is None or retention_days <= 0:
            return 0
        cutoff = (datetime.now(timezone.utc) - timedelta(days=retention_days)).isoformat(
            timespec="seconds"
        )
        with self._conn() as c:
            cur = c.execute("DELETE FROM events WHERE ts < ?", (cutoff,))
            return cur.rowcount or 0
