# AI-operator watchlist guardrail + backlog gate — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make two systemic pitfalls impossible/visible when an AI (or human) operates Paragraphos outside the GUI: (1) a raw `watchlist.yaml` edit being clobbered by the running app, and (2) a silent full-archive backfill with no history-vs-future choice.

**Architecture:** Defense-in-depth on one durable spine — a `backlog_decided:<slug>` meta marker in `state.sqlite`. A blessed CLI (`paragraphos add --backlog`, mandatory) seeds correctly and sets the marker. The running app detects external `watchlist.yaml` changes (watchdog + checkpoint poll, shared content-hash baseline), never clobbers (save-side union-merge), gates undecided shows per-show in the worker, and surfaces a non-blocking banner with a 24h "full history" auto-accept. An `AGENTS.md` points AIs at the CLI.

**Tech Stack:** Python 3.12, Pydantic, PyQt6, watchdog, SQLite, pytest. Pure logic lives in `core/` (Qt-free, unit-tested like `core/scheduler.py` / `core/queue_status.py`).

**Design doc:** `docs/plans/2026-06-25-ai-guardrail-watchlist-design.md` — read it first.

**Conventions to follow:**
- TDD: failing test first, minimal impl, green, commit. One logical change per commit.
- Pure helpers in `core/`, unit-tested with `now`/paths injected (mirror `tests/test_scheduler.py`, `tests/test_queue_status.py`).
- Run unit tests: `.venv/bin/pytest tests/<file> -v`. Pre-commit runs `ruff` + unit pytest.
- Commit message footer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Phase 0 — Shared pure core

### Task 1: `core/backlog.py` — canonical backlog modes (extract from GUI)

Extracts the inline backlog logic in `ui/add_show_dialog.py:1353-1421` into one Qt-free function reused by CLI, GUI dialog, and reconcile dialog (DRY).

**Files:**
- Create: `core/backlog.py`
- Test: `tests/test_backlog.py`

**Step 1: Write the failing test**

```python
# tests/test_backlog.py
import pytest
from core.backlog import parse_backlog, apply_backlog, BacklogError
from core.state import StateStore


def _seed(tmp_path, n=10):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    manifest = []
    for i in range(n):
        guid = f"g{i}"
        # pub_date ascending; i=0 oldest, i=n-1 newest
        pub = f"2026-01-{i+1:02d}T00:00:00"
        st.upsert_episode(show_slug="x", guid=guid, title=f"t{i}",
                          pub_date=pub, mp3_url=f"http://h/{i}.mp3")
        manifest.append({"guid": guid, "pubDate": pub})
    return st, manifest


def _count(st, status):
    with st._conn() as c:
        return c.execute("SELECT COUNT(*) n FROM episodes WHERE show_slug='x' "
                         "AND status=?", (status,)).fetchone()["n"]


def test_parse_canonical_modes():
    assert parse_backlog("all") == ("all", None)
    assert parse_backlog("recent") == ("recent", None)
    assert parse_backlog("last:5") == ("last", 5)
    assert parse_backlog("since:2026-01-05") == ("since", "2026-01-05")


def test_parse_rejects_garbage():
    with pytest.raises(BacklogError):
        parse_backlog("last:notanumber")
    with pytest.raises(BacklogError):
        parse_backlog("since:nope")
    with pytest.raises(BacklogError):
        parse_backlog("bogus")


def test_apply_all_leaves_everything_pending(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("all", None), manifest)
    assert _count(st, "pending") == 10


def test_apply_last_keeps_newest_n(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("last", 3), manifest)
    assert _count(st, "pending") == 3
    assert _count(st, "done") == 7


def test_apply_recent_keeps_one(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("recent", None), manifest)
    assert _count(st, "pending") == 1


def test_apply_since_marks_older_done(tmp_path):
    st, manifest = _seed(tmp_path)
    # keep episodes with pub_date >= 2026-01-06  → i in 5..9 = 5 pending
    apply_backlog(st, "x", ("since", "2026-01-06"), manifest)
    assert _count(st, "pending") == 5
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_backlog.py -v`
Expected: FAIL (module `core.backlog` does not exist).

**Step 3: Write minimal implementation**

```python
# core/backlog.py
"""Canonical backlog ("history vs. future") strategy for a freshly-added show.

One Qt-free entry point reused by the CLI (`paragraphos add --backlog`), the
GUI Add-show dialog, and the app-side reconcile dialog. Modes:
    all              — transcribe the entire archive (leave all pending)
    recent           — keep only the newest episode pending
    last:N           — keep the newest N pending
    since:YYYY-MM-DD  — keep episodes published on/after the date pending
Everything not kept is marked ``done`` so the next check skips it.
"""
from __future__ import annotations

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import List, Optional, Tuple

Mode = Tuple[str, Optional[object]]  # ("last", 5) | ("since", "2026-01-05") | ("all", None)


class BacklogError(ValueError):
    """Raised for an unparseable --backlog value."""


def parse_backlog(raw: str) -> Mode:
    s = (raw or "").strip().lower()
    if s == "all":
        return ("all", None)
    if s == "recent":
        return ("recent", None)
    if s.startswith("last:"):
        try:
            n = int(s.split(":", 1)[1])
        except ValueError:
            raise BacklogError(f"--backlog last:N needs an integer, got {raw!r}")
        if n < 1:
            raise BacklogError("--backlog last:N needs N >= 1")
        return ("last", n)
    if s.startswith("since:"):
        date = raw.split(":", 1)[1].strip()
        try:
            datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise BacklogError(f"--backlog since:DATE needs YYYY-MM-DD, got {date!r}")
        return ("since", date)
    raise BacklogError(
        f"unknown --backlog {raw!r}; use one of: all | recent | last:N | since:YYYY-MM-DD"
    )


def _parse_pubdate(pd: str) -> Optional[datetime]:
    if not pd:
        return None
    try:
        dt = parsedate_to_datetime(pd)
        if dt is not None:
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        pass
    try:
        return datetime.fromisoformat(pd.replace("Z", "+00:00"))
    except ValueError:
        pass
    if len(pd) == 8 and pd.isdigit():  # YouTube YYYYMMDD
        try:
            return datetime.strptime(pd, "%Y%m%d").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


def apply_backlog(state, slug: str, mode: Mode, manifest: List[dict]) -> None:
    """Mark the back-catalog ``done`` per ``mode``. Episodes must already be
    upserted. ``manifest`` is the feed manifest (dicts with guid/pubDate)."""
    kind, arg = mode
    if kind == "all":
        return
    if kind in ("recent", "last"):
        keep = 1 if kind == "recent" else int(arg)
        with state._conn() as c:
            c.execute(
                """UPDATE episodes SET status='done'
                   WHERE show_slug=? AND guid NOT IN (
                       SELECT guid FROM episodes WHERE show_slug=?
                       ORDER BY pub_date DESC LIMIT ?
                   )""",
                (slug, slug, keep),
            )
        return
    if kind == "since":
        cutoff = datetime.strptime(str(arg), "%Y-%m-%d").replace(tzinfo=timezone.utc)
        stale = [
            ep["guid"]
            for ep in manifest
            if (_parse_pubdate(ep.get("pubDate", "")) or cutoff) < cutoff
        ]
        if stale:
            with state._conn() as c:
                ph = ",".join("?" for _ in stale)
                c.execute(
                    f"UPDATE episodes SET status='done' "
                    f"WHERE show_slug=? AND guid IN ({ph})",
                    (slug, *stale),
                )
```

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_backlog.py -v`
Expected: PASS (7 tests).

**Step 5: Commit**

```bash
git add core/backlog.py tests/test_backlog.py
git commit -m "feat(backlog): canonical backlog modes (all/recent/last/since)"
```

---

### Task 2: `core/watchlist_guard.py` — pure guard helpers

**Files:**
- Create: `core/watchlist_guard.py`
- Test: `tests/test_watchlist_guard.py`

**Step 1: Write the failing test**

```python
# tests/test_watchlist_guard.py
from datetime import datetime, timezone
from pathlib import Path

from core.models import Show, Watchlist
from core.state import StateStore
from core.watchlist_guard import (
    DECIDED, DETECTED_AT, GRANDFATHERED,
    file_digest, is_external_change, undecided_slugs,
    mark_decided, mark_detected_now, auto_accept_due, grandfather_existing,
)


def _wl(*slugs):
    return Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in slugs])


def _state(tmp_path):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    return st


def test_file_digest_stable_and_missing(tmp_path):
    p = tmp_path / "w.yaml"
    assert file_digest(p) == ""          # missing → ""
    p.write_text("a: 1")
    d1 = file_digest(p)
    assert d1 and file_digest(p) == d1   # stable
    p.write_text("a: 2")
    assert file_digest(p) != d1          # content-sensitive


def test_is_external_change(tmp_path):
    p = tmp_path / "w.yaml"
    p.write_text("x")
    base = file_digest(p)
    assert is_external_change(p, base) is False
    p.write_text("y")
    assert is_external_change(p, base) is True
    # empty baseline (startup, nothing recorded) is never "external"
    assert is_external_change(p, "") is False


def test_undecided_slugs(tmp_path):
    st = _state(tmp_path)
    wl = _wl("a", "b", "c")
    mark_decided(st, "a")
    assert undecided_slugs(wl, st) == ["b", "c"]


def test_grandfather_marks_all_once(tmp_path):
    st = _state(tmp_path)
    wl = _wl("a", "b")
    assert grandfather_existing(wl, st) is True       # ran
    assert undecided_slugs(wl, st) == []
    assert st.get_meta(GRANDFATHERED) == "1"
    # second call is a no-op (returns False), new shows NOT auto-decided
    wl2 = _wl("a", "b", "c")
    assert grandfather_existing(wl2, st) is False
    assert undecided_slugs(wl2, st) == ["c"]


def test_auto_accept_due(tmp_path):
    st = _state(tmp_path)
    now = datetime(2026, 6, 25, 12, 0, tzinfo=timezone.utc)
    mark_detected_now(st, "b", now=datetime(2026, 6, 24, 11, 0, tzinfo=timezone.utc))
    assert auto_accept_due(st, "b", now=now) is True     # >24h
    mark_detected_now(st, "c", now=datetime(2026, 6, 25, 11, 0, tzinfo=timezone.utc))
    assert auto_accept_due(st, "c", now=now) is False    # <24h
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_watchlist_guard.py -v`
Expected: FAIL (module missing).

**Step 3: Write minimal implementation**

```python
# core/watchlist_guard.py
"""Qt-free guard logic: detect external watchlist.yaml edits, track which
shows have had a backlog decision, and drive the 24h full-history auto-accept.

Meta keys (in state.sqlite ``meta`` table, same pattern as show_paused:<slug>):
    backlog_decided:<slug>      "1" once a backlog choice was made
    backlog_detected_at:<slug>  ISO8601 UTC when first seen undecided
    backlog_grandfathered       "1" after the one-time existing-shows migration
"""
from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Optional

AUTO_ACCEPT_HOURS = 24
GRANDFATHERED = "backlog_grandfathered"


def DECIDED(slug: str) -> str:
    return f"backlog_decided:{slug}"


def DETECTED_AT(slug: str) -> str:
    return f"backlog_detected_at:{slug}"


def file_digest(path: Path) -> str:
    """sha256 hex of the file bytes; "" if the file is missing."""
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except OSError:
        return ""


def is_external_change(path: Path, baseline: str) -> bool:
    """True iff the file differs from a *non-empty* baseline digest."""
    if not baseline:
        return False
    return file_digest(path) != baseline


def is_decided(state, slug: str) -> bool:
    return state.get_meta(DECIDED(slug)) == "1"


def mark_decided(state, slug: str) -> None:
    state.set_meta(DECIDED(slug), "1")


def mark_detected_now(state, slug: str, *, now: datetime) -> None:
    """Stamp first-seen time, only if not already stamped (idempotent)."""
    if not state.get_meta(DETECTED_AT(slug)):
        state.set_meta(DETECTED_AT(slug), now.astimezone(timezone.utc).isoformat())


def undecided_slugs(watchlist, state) -> List[str]:
    return [s.slug for s in watchlist.shows if not is_decided(state, s.slug)]


def auto_accept_due(state, slug: str, *, now: datetime) -> bool:
    raw = state.get_meta(DETECTED_AT(slug))
    if not raw:
        return False
    try:
        detected = datetime.fromisoformat(raw)
    except ValueError:
        return False
    return now.astimezone(timezone.utc) - detected >= timedelta(hours=AUTO_ACCEPT_HOURS)


def grandfather_existing(watchlist, state) -> bool:
    """One-time: mark every show currently in the watchlist as decided so the
    new gate doesn't ambush pre-existing shows. Returns True if it ran."""
    if state.get_meta(GRANDFATHERED) == "1":
        return False
    for s in watchlist.shows:
        mark_decided(state, s.slug)
    state.set_meta(GRANDFATHERED, "1")
    return True
```

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_watchlist_guard.py -v`
Expected: PASS.

**Step 5: Commit**

```bash
git add core/watchlist_guard.py tests/test_watchlist_guard.py
git commit -m "feat(guard): pure watchlist-guard helpers (digest, decided, 24h auto-accept)"
```

---

## Phase 1 — Grandfather migration on load

### Task 3: run grandfather + record baseline hash in `AppContext.load`

**Files:**
- Modify: `ui/app_context.py` (`AppContext.load`, after `watchlist`/`state` are built; add `_watchlist_hash` field)
- Test: `tests/test_app_context_grandfather.py`

**Step 1: Write the failing test**

```python
# tests/test_app_context_grandfather.py
from core.watchlist_guard import GRANDFATHERED, is_decided
from core.models import Watchlist, Show
from ui.app_context import AppContext


def test_load_grandfathers_existing_shows_and_sets_hash(tmp_path):
    (tmp_path / "watchlist.yaml").write_text(
        "shows:\n- {slug: a, title: A, rss: 'http://h/a'}\n", encoding="utf-8"
    )
    ctx = AppContext.load(tmp_path)
    assert ctx.state.get_meta(GRANDFATHERED) == "1"
    assert is_decided(ctx.state, "a")
    assert ctx._watchlist_hash  # baseline recorded
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_app_context_grandfather.py -v`
Expected: FAIL (no grandfathering / no `_watchlist_hash`).

**Step 3: Implement**

In `ui/app_context.py`:
- Add field to the dataclass (near `update_available_url`): `_watchlist_hash: str = ""`.
- In `AppContext.load`, after `watchlist = Watchlist.load(...)` and `state.init_schema()`/`recover_in_flight()`, before constructing the return:

```python
from core.watchlist_guard import file_digest, grandfather_existing
grandfather_existing(watchlist, state)
_wl_hash = file_digest(data_dir / "watchlist.yaml")
```

- Pass it into the constructor: add `, _watchlist_hash=_wl_hash` (or set after construction: `ctx._watchlist_hash = _wl_hash; return ctx`). Keep field order valid.

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_app_context_grandfather.py -v`
Expected: PASS. Then `.venv/bin/pytest tests/test_app_setup_wiring.py -v` to confirm no regression in load.

**Step 5: Commit**

```bash
git add ui/app_context.py tests/test_app_context_grandfather.py
git commit -m "feat(guard): grandfather existing shows + record watchlist baseline on load"
```

---

## Phase 2 — Worker gate (prevents silent backfill)

### Task 4: skip undecided shows in the worker fetch loop

**Files:**
- Modify: `ui/worker_thread.py:561` (the `fetch_targets` filter loop)
- Test: `tests/test_worker_backlog_gate.py`

**Step 1: Write the failing test**

The fetch-target filter is currently inline. To make it unit-testable without spinning a thread, extract the per-show skip predicate into a tiny pure helper and test that; then the loop calls it.

```python
# tests/test_worker_backlog_gate.py
from core.state import StateStore
from core.watchlist_guard import mark_decided
from ui.worker_thread import show_is_gated


def _st(tmp_path):
    st = StateStore(tmp_path / "s.sqlite"); st.init_schema(); return st


def test_undecided_show_is_gated(tmp_path):
    st = _st(tmp_path)
    assert show_is_gated(st, "newshow") is True       # no marker → gated


def test_decided_show_not_gated(tmp_path):
    st = _st(tmp_path)
    mark_decided(st, "ok")
    assert show_is_gated(st, "ok") is False


def test_paused_still_gated(tmp_path):
    st = _st(tmp_path)
    mark_decided(st, "p")
    st.set_meta("show_paused:p", "1")
    assert show_is_gated(st, "p") is True             # paused OR undecided
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_worker_backlog_gate.py -v`
Expected: FAIL (`show_is_gated` undefined).

**Step 3: Implement**

Add a module-level helper in `ui/worker_thread.py` (Qt-free):

```python
def show_is_gated(state, slug: str) -> bool:
    """A show is skipped this pass if it is per-show paused OR has no backlog
    decision yet (an externally-added show awaiting the reconcile choice)."""
    from core.watchlist_guard import is_decided
    if state.get_meta(f"show_paused:{slug}") == "1":
        return True
    return not is_decided(state, slug)
```

Replace the paused check at `ui/worker_thread.py:561-563` with:

```python
            if show_is_gated(self.ctx.state, show.slug):
                self.progress.emit(f"skip {show.slug} (paused or backlog undecided)")
                continue
```

This is per-show: decided shows still enter `fetch_targets` and run normally — the daily check is never globally blocked.

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_worker_backlog_gate.py tests/test_pipeline.py -v`
Expected: PASS (gate tests + existing pipeline tests unaffected; existing shows are grandfathered/decided in real runs).

**Step 5: Commit**

```bash
git add ui/worker_thread.py tests/test_worker_backlog_gate.py
git commit -m "feat(guard): gate undecided shows in worker fetch loop (per-show, non-blocking)"
```

---

## Phase 3 — Blessed CLI (`paragraphos add --backlog`)

### Task 5: make `--backlog` a required, validated arg on `add`

**Files:**
- Modify: `cli.py` (the `add` subparser at `cli.py:1031-1033`; add args)
- Test: `tests/test_cli_parser.py` (append)

**Step 1: Write the failing test**

```python
# tests/test_cli_parser.py  (append)
import pytest
from cli import build_parser  # see Step 3 note if parser isn't already factored


def test_add_requires_backlog():
    p = build_parser()
    with pytest.raises(SystemExit):
        p.parse_args(["add", "Some Podcast"])          # missing --backlog → error


def test_add_accepts_backlog_and_flags():
    p = build_parser()
    ns = p.parse_args(["add", "http://h/rss", "--backlog", "last:5",
                       "--slug", "x", "--lang", "de", "--yes"])
    assert ns.backlog == "last:5" and ns.slug == "x" and ns.yes is True
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_cli_parser.py -v`
Expected: FAIL.

**Step 3: Implement**

In `cli.py`, the parser is built inside `main()`. Factor it into `build_parser()` (return `p`) and have `main()` call it — `tests/test_cli_parser.py` already imports a parser factory; match whatever it uses (check the top of that test file and reuse the existing name if present). On the `add` subparser add:

```python
    a.add_argument("--backlog", required=True,
                   help="all | recent | last:N | since:YYYY-MM-DD")
    a.add_argument("--slug", default=None, help="override the derived slug")
    a.add_argument("--lang", default=None, help="whisper language code (default de)")
    a.add_argument("--yes", action="store_true",
                   help="non-interactive: accept the first iTunes match / derived slug")
```

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_cli_parser.py -v`
Expected: PASS.

**Step 5: Commit**

```bash
git add cli.py tests/test_cli_parser.py
git commit -m "feat(cli): require --backlog on add; add --slug/--lang/--yes"
```

---

### Task 6: wire `cmd_add` to seed + apply backlog + set marker (atomic, non-interactive)

**Files:**
- Modify: `cli.py` `cmd_add` (`cli.py:120-166`)
- Add: an atomic-write helper for the watchlist (`core/models.py` `Watchlist.save_atomic` OR a local helper in cli)
- Test: `tests/test_cli_add_backlog.py`

**Step 1: Write the failing test**

```python
# tests/test_cli_add_backlog.py
import argparse
import core.paths
import cli
from core.backlog import parse_backlog
from core.watchlist_guard import is_decided


def _run_add(tmp_path, monkeypatch, backlog):
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    # stub network: feed metadata + manifest
    monkeypatch.setattr(cli, "find_rss_from_url", lambda u: "http://h/rss")
    monkeypatch.setattr(cli, "feed_metadata", lambda rss: {"title": "Pod X", "author": "A"})
    manifest = [{"guid": f"g{i}", "title": f"t{i}",
                 "pubDate": f"2026-01-{i+1:02d}T00:00:00", "mp3_url": f"http://h/{i}.mp3",
                 "description": ""} for i in range(10)]
    monkeypatch.setattr(cli, "build_manifest", lambda rss: manifest)
    monkeypatch.setattr(cli, "suggest_whisper_prompt", lambda **k: "prompt")
    ns = argparse.Namespace(name_or_url="http://h/rss", backlog=backlog,
                            slug="pod-x", lang="de", yes=True)
    return cli.cmd_add(ns)


def test_add_last5_seeds_5_pending_and_marks_decided(tmp_path, monkeypatch):
    rc = _run_add(tmp_path, monkeypatch, "last:5")
    assert rc == 0
    from core.state import StateStore
    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        pend = c.execute("SELECT COUNT(*) n FROM episodes "
                         "WHERE show_slug='pod-x' AND status='pending'").fetchone()["n"]
    assert pend == 5
    assert is_decided(st, "pod-x")


def test_add_all_seeds_everything_pending(tmp_path, monkeypatch):
    _run_add(tmp_path, monkeypatch, "all")
    from core.state import StateStore
    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        pend = c.execute("SELECT COUNT(*) n FROM episodes "
                         "WHERE show_slug='pod-x' AND status='pending'").fetchone()["n"]
    assert pend == 10
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_cli_add_backlog.py -v`
Expected: FAIL.

**Step 3: Implement**

Rewrite `cmd_add` (`cli.py:120`) so it:
1. Parses `args.backlog` via `parse_backlog` up front (so a bad value fails before any network/IO).
2. In non-interactive mode (`args.yes`): for a name (not URL), take `matches[0]`; skip the `input()` prompts; use `args.slug` or derived slug; use suggested prompt (no override prompt).
3. Writes the watchlist atomically and seeds + applies backlog + sets the marker.

Key additions (keep the existing interactive path when `not args.yes`):

```python
    mode = parse_backlog(args.backlog)   # raises BacklogError → caught in main()
    ...
    slug = (getattr(args, "slug", None) or slug_default)
    ...
    wl.shows.append(Show(slug=slug, title=meta["title"], rss=rss, whisper_prompt=prompt,
                         language=(getattr(args, "lang", None) or "de")))
    _save_watchlist_atomic(wl, DATA / "watchlist.yaml")

    state = _state()
    from core.stats import _parse_duration as _pd
    for ep in manifest:
        state.upsert_episode(show_slug=slug, guid=ep["guid"], title=ep["title"],
                             pub_date=ep["pubDate"], mp3_url=ep["mp3_url"],
                             duration_sec=_pd(ep.get("duration", "")))
    from core.backlog import apply_backlog
    from core.watchlist_guard import mark_decided
    apply_backlog(state, slug, mode, manifest)
    mark_decided(state, slug)
    print(f"added '{slug}' ({len(manifest)} episodes, backlog={args.backlog})")
    return 0
```

Add the atomic writer (in `cli.py`, or as `Watchlist.save_atomic` in `core/models.py` and call that — preferred for reuse by Task 7):

```python
# core/models.py — method on Watchlist
def save_atomic(self, path: Path) -> None:
    import os, tempfile
    path.parent.mkdir(parents=True, exist_ok=True)
    data = yaml.safe_dump(self.model_dump(), allow_unicode=True, sort_keys=False)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, path)   # atomic on POSIX
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
```

Wrap `cmd_add` body's `BacklogError` at the `main()` dispatch (or locally) to print the message and `return 2`.

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_cli_add_backlog.py tests/test_cli_parser.py -v`
Expected: PASS.

**Step 5: Commit**

```bash
git add cli.py core/models.py tests/test_cli_add_backlog.py
git commit -m "feat(cli): add seeds state, applies --backlog, sets decided marker (atomic write)"
```

---

## Phase 4 — App-guard: no-clobber save + reload checkpoints

### Task 7: save-side union-merge gate (closes the clobber race)

**Files:**
- Create: `core/watchlist_io.py` (`save_watchlist(ctx)`, `reload_watchlist(ctx)`)
- Modify: every in-app save site to call `save_watchlist(ctx)` instead of `ctx.watchlist.save(...)` — sites: `ui/shows_tab.py:681,708,716,742`, `ui/show_details_dialog.py:354,945,974`, `ui/menu_bar.py:305`, `ui/worker_thread.py:623`, `app.py:771,822`, `ui/add_show_dialog.py:1340`.
- Test: `tests/test_watchlist_io.py`

**Step 1: Write the failing test (the incident repro)**

```python
# tests/test_watchlist_io.py
from types import SimpleNamespace
from core.models import Watchlist, Show
from core.state import StateStore
from core.watchlist_guard import file_digest
from core.watchlist_io import save_watchlist, reload_watchlist


def _ctx(tmp_path, slugs):
    wl = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in slugs])
    path = tmp_path / "watchlist.yaml"
    wl.save(path)
    st = StateStore(tmp_path / "s.sqlite"); st.init_schema()
    return SimpleNamespace(data_dir=tmp_path, watchlist=wl, state=st,
                           _watchlist_hash=file_digest(path))


def test_save_does_not_clobber_external_additions(tmp_path):
    # App loaded 2 shows; baseline recorded.
    ctx = _ctx(tmp_path, ["a", "b"])
    # External edit adds "c" (and "d") directly to the file.
    ext = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in ["a", "b", "c", "d"]])
    ext.save(tmp_path / "watchlist.yaml")
    # App mutates its stale in-memory copy (toggle b) and saves.
    ctx.watchlist.shows[1].enabled = False
    save_watchlist(ctx)
    on_disk = Watchlist.load(tmp_path / "watchlist.yaml")
    slugs = {s.slug for s in on_disk.shows}
    assert slugs == {"a", "b", "c", "d"}          # external shows survived
    assert next(s for s in on_disk.shows if s.slug == "b").enabled is False  # mutation kept


def test_reload_adopts_external_and_reports_added(tmp_path):
    ctx = _ctx(tmp_path, ["a"])
    ext = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in ["a", "z"]])
    ext.save(tmp_path / "watchlist.yaml")
    added = reload_watchlist(ctx)
    assert added == ["z"]
    assert {s.slug for s in ctx.watchlist.shows} == {"a", "z"}
    assert ctx._watchlist_hash == file_digest(tmp_path / "watchlist.yaml")
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_watchlist_io.py -v`
Expected: FAIL (module missing).

**Step 3: Implement**

```python
# core/watchlist_io.py
"""Clobber-safe watchlist persistence + reload for the running app.

save_watchlist: before writing, if the on-disk file changed since our baseline
(an external edit we haven't reconciled), union-merge any disk-only shows back
in so we never drop them. Then write atomically and refresh the baseline.

reload_watchlist: adopt the on-disk file as truth, return newly-appeared slugs.
"""
from __future__ import annotations

from typing import List

from core.models import Watchlist
from core.watchlist_guard import file_digest, is_external_change


def _path(ctx):
    return ctx.data_dir / "watchlist.yaml"


def save_watchlist(ctx) -> None:
    path = _path(ctx)
    baseline = getattr(ctx, "_watchlist_hash", "")
    if is_external_change(path, baseline):
        disk = Watchlist.load(path)
        have = {s.slug for s in ctx.watchlist.shows}
        for s in disk.shows:
            if s.slug not in have:               # disk-only → preserve
                ctx.watchlist.shows.append(s)
    ctx.watchlist.save_atomic(path)
    ctx._watchlist_hash = file_digest(path)


def reload_watchlist(ctx) -> List[str]:
    path = _path(ctx)
    before = {s.slug for s in ctx.watchlist.shows}
    try:
        disk = Watchlist.load(path)
    except Exception:
        return []                                # half-written / invalid → leave as-is
    ctx.watchlist = disk
    ctx._watchlist_hash = file_digest(path)
    return [s.slug for s in disk.shows if s.slug not in before]
```

Then replace each `ctx.watchlist.save(ctx.data_dir / "watchlist.yaml")` call (the sites listed in **Files**) with `from core.watchlist_io import save_watchlist` + `save_watchlist(ctx)`. For `ui/add_show_dialog.py:1340` it's `self.updated_watchlist.save(...)` — leave the GUI add path writing its own object, but follow with a baseline refresh if it shares `ctx`; simplest: keep add_show_dialog as-is (it sets the marker in Task 13's sibling change) and refresh `ctx._watchlist_hash` after. (Note in plan: add-dialog writes `updated_watchlist`, not `ctx.watchlist`; after save do `ctx._watchlist_hash = file_digest(path)` to avoid a false "external change".)

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_watchlist_io.py -v`
Then regression: `.venv/bin/pytest tests/test_shows_tab*.py tests/test_show_details*.py -v` (whichever exist).

**Step 5: Commit**

```bash
git add core/watchlist_io.py core/models.py tests/test_watchlist_io.py ui/ app.py
git commit -m "feat(guard): clobber-safe save_watchlist (union-merge) + reload_watchlist"
```

---

### Task 8: pre-run + activation reload checkpoints

**Files:**
- Modify: `app.py` `_run_check` (`app.py:489`, at the very top) and `_on_app_activated` (`app.py:515`)
- Add: `MainApp._maybe_reload_watchlist()` that calls `reload_watchlist(ctx)` + triggers reconcile (Task 11/12) when slugs appear
- Test: `tests/test_run_check_reloads_watchlist.py`

**Step 1: Write the failing test**

```python
# tests/test_run_check_reloads_watchlist.py
# Verify _run_check reloads an externally-changed watchlist BEFORE checking.
# Mirror the lightweight wiring style of tests/test_app_activation_catchup.py:
# build a minimal app object with a stubbed window/thread, point ctx at a temp
# dir, mutate the file on disk, call _maybe_reload_watchlist(), assert the new
# slug is now in ctx.watchlist and is gated (undecided).
```

(Write the concrete test mirroring `tests/test_app_activation_catchup.py`'s harness — it already constructs the app with a fake ctx. Assert: after an external add + `_maybe_reload_watchlist()`, `ctx.watchlist` contains the new slug and `is_decided(ctx.state, new) is False`.)

**Step 2: Run to verify it fails**

Run: `.venv/bin/pytest tests/test_run_check_reloads_watchlist.py -v`
Expected: FAIL.

**Step 3: Implement**

```python
# app.py — method on the app class
def _maybe_reload_watchlist(self) -> None:
    from core.watchlist_io import reload_watchlist
    from core.watchlist_guard import file_digest, is_external_change
    path = self.ctx.data_dir / "watchlist.yaml"
    if not is_external_change(path, getattr(self.ctx, "_watchlist_hash", "")):
        return
    added = reload_watchlist(self.ctx)
    if added:
        self._reconcile_new_shows(added)   # Task 11/12 — stamp detected_at + banner
```

At the top of `_run_check` (before the `if self._window` branch): `self._maybe_reload_watchlist()`.
In `_on_app_activated`, when the app becomes active (mirror the existing `Qt.ApplicationState.ApplicationActive` guard used there), call `self._maybe_reload_watchlist()`.

**Step 4: Run to verify pass**

Run: `.venv/bin/pytest tests/test_run_check_reloads_watchlist.py tests/test_app_activation_catchup.py -v`
Expected: PASS.

**Step 5: Commit**

```bash
git add app.py tests/test_run_check_reloads_watchlist.py
git commit -m "feat(guard): reload watchlist on activation + before every run"
```

---

### Task 9: watchdog observer on `watchlist.yaml`

**Files:**
- Modify: `ui/app_context.py` (extend `start_watching`/observer setup, or add a sibling observer) — mirror `core/library.py:135-174`
- Test: `tests/test_watchlist_observer.py` (assert the handler fires `_maybe_reload`-style callback on modify; debounce + hash check make own-writes no-ops)

**Steps:** Follow the same TDD shape. The observer is thin — schedule a `FileSystemEventHandler` on `data_dir` filtering `watchlist.yaml`, debounced (≥250ms), whose callback marshals to the GUI thread (Qt signal) and calls `_maybe_reload_watchlist()`. The hash check inside `_maybe_reload_watchlist` already suppresses own-save events, so the test asserts: external write → callback reloads; own `save_watchlist` → no reload (hash equal). Keep the OS-level watcher untested directly (flaky); test the callback wiring + the hash-suppression decision. Commit:

```bash
git commit -m "feat(guard): watchdog observer on watchlist.yaml (debounced, hash-suppressed)"
```

---

## Phase 5 — Banner, reconcile dialog, 24h auto-accept

### Task 10: 24h auto-accept sweep at checkpoints

**Files:**
- Add: `MainApp._auto_accept_overdue()` — for each undecided slug, if `auto_accept_due` → `mark_decided` (full history; no seeding) + clear banner if empty
- Call it from `_maybe_reload_watchlist` and the daily tick / `_run_check` top
- Test: `tests/test_auto_accept_sweep.py` (inject `now`; overdue slug becomes decided, fresh one stays undecided)

**Steps:** TDD as above. Core logic is already pure (`auto_accept_due` + `mark_decided`); the app method loops `undecided_slugs(ctx.watchlist, ctx.state)`. Pass `now` via a small injectable (default `datetime.now(timezone.utc)`; tests pass a fixed value). Commit:

```bash
git commit -m "feat(guard): 24h full-history auto-accept sweep for undecided shows"
```

---

### Task 11: new-show banner state in MainWindow

**Files:**
- Modify: `ui/main_window.py` (banner is `self.banner`, `self._banner_state` at `:113-128`; add a `"newshow"` state + setter `set_newshow_banner(slugs)`)
- Test: `tests/test_main_window_banner.py` (append — mirror existing banner-state assertions)

**Steps:** Add a `"newshow"` banner variant: amber styling, label `"N new show(s) detected — choose how much history (full history in 24h)"`, action button `"Choose…"` wired to open the reconcile dialog (Task 12), dismiss hides it (but the gate/auto-accept still apply). Follow the exact pattern of the `"offline"`/`"update"` states already in this file and the assertions in `tests/test_main_window_banner.py`. Commit:

```bash
git commit -m "feat(guard): 'new show detected' banner state in main window"
```

---

### Task 12: reconcile dialog (per-show backlog choice, default full history)

**Files:**
- Create: `ui/reconcile_dialog.py`
- Modify: `ui/main_window.py` banner action → open it; on accept apply choices
- Test: `tests/test_reconcile_dialog.py`

**Steps:** A `QDialog` listing each undecided slug with a backlog selector **pre-selected to "All / full history"** (reuse the `_backlog_row` widget pattern from `ui/add_show_dialog.py:823`, or a compact combo with `all|recent|last:5|last:10|since:…`). On accept, for each show: fetch its manifest (`core.rss.build_manifest`), upsert episodes, `apply_backlog(state, slug, parse_backlog(choice), manifest)`, `mark_decided(state, slug)`, then `save_watchlist(ctx)` (no-op merge) and refresh the Shows tab. Test the **apply wiring** with a stubbed manifest (not the Qt exec loop): a helper `apply_reconcile_choice(ctx, slug, "last:5", manifest)` that the dialog calls, asserting pending count + marker. Keep Qt-thin; put the logic in the helper so it's unit-testable. Commit:

```bash
git commit -m "feat(guard): reconcile dialog to choose backlog for externally-added shows"
```

---

## Phase 6 — Discoverability & changelog

### Task 13: `AGENTS.md` + curated CHANGELOG entry

**Files:**
- Create: `AGENTS.md` (repo root)
- Modify: `CHANGELOG.md` (curated highlight, not a raw dump — house rule)
- Test: `tests/test_agents_doc.py` (assert `AGENTS.md` exists and names `paragraphos add` + `--backlog` + "never edit watchlist.yaml directly")

**Step 1: failing test**

```python
# tests/test_agents_doc.py
from pathlib import Path
def test_agents_doc_mentions_blessed_path():
    txt = Path("AGENTS.md").read_text(encoding="utf-8")
    assert "paragraphos add" in txt and "--backlog" in txt
    assert "watchlist.yaml" in txt
```

**Step 2-4:** Create `AGENTS.md` with the operator block from the design doc (blessed CLI, the two why's, `paragraphos status`). Add a concise curated `CHANGELOG.md` entry under the current unreleased section. Run the test green.

**Step 5: Commit**

```bash
git add AGENTS.md CHANGELOG.md tests/test_agents_doc.py
git commit -m "docs(agents): AGENTS.md guardrail guidance + changelog"
```

---

## Final verification

```bash
.venv/bin/pytest tests/ -q          # full unit suite green
.venv/bin/ruff check .              # lint clean
```

Manual smoke (optional, app quit): `paragraphos add "<feed>" --backlog last:5` → verify `shows` lists it with 5 pending + decided; raw-edit `watchlist.yaml` while app runs → on focus the banner appears and the show is gated.

## Notes / gotchas for the implementer

- **Existing shows are grandfathered** (Task 3) — the gate only ever fires for shows that appear *after* this version's first launch. The user's current 3 shows (531 pending, full archive) are unaffected.
- **Own-save suppression** hinges on every save going through `save_watchlist` (Task 7) so `_watchlist_hash` stays current. If you find a save site not on the list, route it too.
- **`since:` semantics** match the GUI's "Time:" handling (defensive pubDate parse). Keep `core/backlog.py` the single source.
- Don't introduce a global queue pause anywhere — gating is strictly per-show.
