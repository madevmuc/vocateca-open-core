# Homebrew Cask (draft)

> **DRAFT — nothing submitted anywhere.** `Casks/vocateca.rb` in this repo is a
> local working copy for authoring + testing only. Opening a PR against
> `Homebrew/homebrew-cask` is a separate, **USER-approved**, outward-facing
> step — do not open it without explicit sign-off.

## Current state

- Built against the currently *published* stable release, **2.2.1**
  (`https://vocateca.com/releases/Vocateca-2.2.1.dmg`).
- sha256 verified two ways: hashing the on-disk file at
  `~/dev/OS/apps/marketing/vocateca/public/releases/Vocateca-2.2.1.dmg` and
  hashing a fresh `curl` download of the served URL — both produced
  `0ac9d74ae90f06a973fe4646578bffc164dc9ec8b38552877f40bc23b8da1646`.

## Bumping the cask for a new release

1. Ship the release normally (`release.sh` / the standard notarize + Sparkle
   pipeline) so a DMG lands at `https://vocateca.com/releases/Vocateca-<version>.dmg`.
2. Compute the sha256 of the **served** file, not just the local build
   artifact, in case anything touches it in transit:
   ```sh
   curl -sL -o /tmp/Vocateca-<version>.dmg \
     https://vocateca.com/releases/Vocateca-<version>.dmg
   shasum -a 256 /tmp/Vocateca-<version>.dmg
   ```
3. Update `version` and `sha256` in `Casks/vocateca.rb` (that's it — the `url`
   is templated off `#{version}`).
4. Re-test locally before touching the real tap. As of Homebrew 6.x, `brew
   install`/`brew audit` reject a bare file path ("Homebrew requires casks to
   be in a tap") — stage it in a throwaway local tap first:
   ```sh
   brew tap-new local/vocateca-test --no-git
   mkdir -p "$(brew --repository local/vocateca-test)/Casks/v"
   cp Casks/vocateca.rb "$(brew --repository local/vocateca-test)/Casks/v/vocateca.rb"
   brew style --cask local/vocateca-test/vocateca
   brew audit --cask --new local/vocateca-test/vocateca
   brew install --cask local/vocateca-test/vocateca
   open -a Vocateca   # sanity check it launches
   brew uninstall --cask vocateca
   brew untap local/vocateca-test
   ```
   **Caution:** if a non-Homebrew copy of `Vocateca.app` is already in
   `/Applications` (e.g. the real day-to-day install), `brew install --cask`
   will refuse to proceed without `--force`, and `--force` will move that
   existing app aside. Do not run the install step against a machine with a
   live, in-use Vocateca install without confirming with whoever uses that
   Mac first — verify the DMG in isolation instead (mount read-only, check
   `codesign -dv`, don't touch `/Applications`) if that's not possible.
5. Only after a human explicitly approves it: fork `Homebrew/homebrew-cask`,
   copy the file to `Casks/v/vocateca.rb` there, and open the PR per their
   contribution guide. This is the "outward-facing" step referenced above —
   it must not happen automatically.

## Known gap: `brew audit --new` fails right now (expected, not a bug)

`brew audit --cask --new` runs a livecheck against `livecheck do url
"https://vocateca.com/appcast.xml"; strategy :sparkle end` and, as of this
writing, that appcast's newest `<item>` is **2.2.2** (build 20202) — but
2.2.2 only has a published `.zip` (Sparkle update), no `.dmg` yet. The cask
is deliberately pinned to **2.2.1**, the newest version with a published DMG,
so the audit correctly (if inconveniently) reports:

```
Version '2.2.1' differs from '2.2.2,20202' retrieved by livecheck.
```

**Do not silence this by pointing the cask at a nonexistent DMG.** Fix it by
publishing a DMG for the next release and bumping the cask to match — see
the bump steps above. This also means: once this cask is live in
`Homebrew/homebrew-cask`, every release needs a DMG published at the same
time as (or before) the Sparkle zip/appcast update, or Homebrew's own
livecheck automation will immediately flag the cask as outdated.

## Known gap: `zap` vs. Keychain

The cask's `zap trash:` stanza removes the on-disk Application Support /
Caches / Preferences paths, matching `AppDataReset.wipeEverything()` in
`VocatecaCore`. It does **not** and cannot clear the three Keychain services
that function also clears (`com.vocateca.instagram`, `com.vocateca.integrations`,
`com.vocateca.webhooks`) — Homebrew Cask has no Keychain-removal primitive.
Users who want a full wipe should use the in-app factory reset before
uninstalling via Homebrew.
