"""SQLite state store for episodes/jobs/meta."""

from __future__ import annotations

import hashlib
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterator, Optional


class EpisodeStatus(str, Enum):
    PENDING = "pending"
    DOWNLOADING = "downloading"
    DOWNLOADED = "downloaded"
    TRANSCRIBING = "transcribing"
    DONE = "done"
    FAILED = "failed"
    STALE = "stale"


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

    def set_priority(self, guid: str, priority: int) -> None:
        with self._conn() as c:
            c.execute("UPDATE episodes SET priority=? WHERE guid=?", (priority, guid))

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
        with self._conn() as c:
            if status == EpisodeStatus.DONE:
                c.execute(
                    "UPDATE episodes SET status=?, completed_at=?, error_text=NULL WHERE guid=?",
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
