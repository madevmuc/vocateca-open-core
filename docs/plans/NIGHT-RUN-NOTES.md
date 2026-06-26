# Night-run notes (2026-06-26)

Autonomous execution of the roadmap program. Spec:
[`2026-06-26-roadmap-execution-design.md`](2026-06-26-roadmap-execution-design.md) ·
Plan: [`2026-06-26-roadmap-execution-plan.md`](2026-06-26-roadmap-execution-plan.md)

## Operating decisions (confirmed with Matthias before the run)

1. **Execution mode:** sequential in the main loop — one task at a time, full
   RITUAL per task (TDD where practical → full pytest green → ruff clean →
   CHANGELOG/AGENTS/CLI/NOTES → one Conventional Commit). No subagent fan-out
   (hot files overlap too much).
2. **Dependencies:** add permissively-licensed OSS deps to `requirements.txt`
   as features need them. Diarization model download stays gated + off.
3. **Finalisation:** push `feat/roadmap-execution` and open a normal
   (ready-for-review) PR against `main`. Do **not** merge.
4. **Fallback:** any blocked feature (not just the 6 flagged L-items) may fall
   back to a focused design doc + flag-gated skeleton, recorded here, then
   continue. Never stop to ask.

## Baseline (Task 0)

- Branch `feat/roadmap-execution`, Python 3.12.3, `.venv` present.
- Clean-tree baseline **green**: `720 passed, 1 deselected` (pytest, offscreen
  Qt, `--timeout=180`); `ruff check` + `ruff format --check` clean.

## Progress log

- **Task 0 — run setup** ✅ baseline verified green; notes scaffold created.
