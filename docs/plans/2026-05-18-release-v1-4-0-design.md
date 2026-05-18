# Release v1.4.0 — Design

**Datum:** 2026-05-18
**Status:** Approved, ready for implementation plan

## Ziel

Release `v1.4.0` schneiden: Version bumpen, CHANGELOG schreiben, README-Badge
aktualisieren, nach `main` pushen, dann Tag `v1.4.0` pushen — was
`build-release.yml` triggert und eine **Draft**-Release mit DMG + Auto-Notes
erzeugt. Aktuelle Version: `1.3.3`. Seit `v1.3.3` liegen 28 Commits auf main
(zwei Features + Fixes + CI/Docs).

## Entscheidungen (aus Brainstorming)

- **Version:** `1.4.0` (SemVer Minor — zwei neue, abwärtskompatible Features).
- **CHANGELOG-Umfang:** nur User-sichtbares (Features + user-sichtbare Fixes);
  reine CI/Docs/Infra-Commits weggelassen.
- **Tag-Push:** automatisch als letzter Prozess-Schritt (vom Nutzer
  ausdrücklich vorab autorisiert), keine separate Rückfrage im Moment.
- **Publish:** NICHT durch den Agenten — die Draft-Release publisht der
  Nutzer manuell (erst das lässt `releases/latest` umschlagen und löst
  Nutzer-Update-Benachrichtigungen aus).

## Mechanik (verifiziert)

- Single source of truth: `core/version.py` `VERSION` + `pyproject.toml`
  `version`. `tests/test_version.py` erzwingt: SemVer-Form, pyproject ==
  VERSION, setup*.py importieren `VERSION` symbolisch, about_dialog
  importiert `VERSION`. → Bump betrifft nur `core/version.py` +
  `pyproject.toml`.
- `build-release.yml` triggert **ausschließlich** auf `push: tags: ['v*']`,
  läuft auf `macos-14`, baut `.app` via `setup-full.py py2app`, DMG via
  `scripts/build-dmg.sh "${GITHUB_REF_NAME#v}"`, lädt Artefakt hoch und
  hängt das DMG an eine `softprops/action-gh-release@v2`-Release mit
  `draft: true` + `generate_release_notes: true`.
- Draft-Release ⇒ unsichtbar für `releases/latest` ⇒ kein Nutzer-
  Update-Trigger bis zum manuellen Publish.

## Komponenten

### 1. Version-Bump
- `core/version.py`: `VERSION = "1.4.0"`
- `pyproject.toml`: `version = "1.4.0"`

### 2. CHANGELOG.md
Neuer Eintrag direkt über `## v1.3.3`:
`## v1.4.0 — 2026-05-18 (App-activation catch-up & update check)`

- **### Added**
  - Verpasster täglicher Check wird beim nächsten App-Vordergrund
    nachgeholt (Mac war aus / busy / Check scheiterte) — schließt die
    Lücke bei dauerhaft im Tray laufender App.
  - Periodischer Update-Check beim App-Vordergrund (≤1×/24 h) plus neues
    Setting „Check for updates"; Update-Tray-Benachrichtigung jetzt nur
    noch einmal pro Version statt bei jedem Start.
- **### Fixed**
  - Discovery (iTunes-Suche + Cover-Fetch) läuft jetzt über den
    gemeinsamen httpx-Client.
  - Worker-Orphan-Claim auf den Run-Start-Snapshot begrenzt — verhindert
    `done_idx > total` in der Fortschrittsanzeige.

Detailtiefe + Prosa im Stil der bestehenden Einträge (Was/Warum).

### 3. README-Badge
`![Status](https://img.shields.io/badge/status-v1.3.0-green)` →
`status-v1.4.0`. (Aktuell sogar auf v1.3.0 statt 1.3.3 — bei der
Gelegenheit korrigiert.) Test-Count-Badge bleibt (nicht release-kritisch,
schwankt).

### 4. Verifikation vor Push
Volle Test-Suite grün (insb. `tests/test_version.py`), ruff clean.
Pre-commit-Hook (ruff + ruff format + pytest) deckt staged Files ab.

### 5. Commit + Push auf `main`
Ein Commit `release: v1.4.0` (version + changelog + readme-badge), nach
`main` gepusht. Tag muss auf einem main-Commit sitzen — wie bei `v1.3.3`,
kein Feature-Branch (Release-Commit gehört konventionell auf main).

### 6. Tag + Tag-Push (Release-Trigger)
`git tag v1.4.0 && git push origin v1.4.0` → `build-release.yml`.

### 7. Nach dem Trigger
`build-release`-Run via GitHub-API (unauth, public) überwachen bis
`completed`; Conclusion + Draft-Release-URL melden. Kein Publish.

## Fehlerbehandlung

- `test_version.py` / Suite rot → Stopp vor jedem Push, nichts taggen.
- `build-release`-Run `failure` → Logs/Conclusion melden; Tag nach
  Rücksprache zurückziehbar (`git push --delete origin v1.4.0` +
  `git tag -d v1.4.0`).
- Tag existiert schon remote → Stopp, nachfragen (kein Force-Push).

## YAGNI / bewusste Entscheidungen

- Keine GitHub-Release-Publish-Automatisierung (bewusst manuell beim
  Nutzer — nach-außen-wirkend, löst Nutzer-Updates aus).
- Keine README-Test-Count-Badge-Pflege (schwankt, nicht release-relevant).
- Reine CI/Docs-Commits nicht im CHANGELOG (User-Sicht-Kuratierung).
