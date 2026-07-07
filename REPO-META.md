# Repo metadata (suggested — not applied anywhere)

This file is local prep only. Nothing in this repository has been published, and no GitHub
repo, remote, or `gh` command has been run. **Publishing is pending your explicit go-ahead.**
When you're ready, the exact publish steps (repo creation, remote, topics, update-checker
slug fix, marketing-page link) are in
`/Users/matthiasmaier/dev/paragraphos/docs/open-core-overnight-report.md`, section 7.

---

## Suggested GitHub "About" description

> Local-first, on-device transcription engine + CLI + MCP server for podcasts, YouTube, and Instagram — the open core of Vocateca.

(140 characters — fits GitHub's About field. Swap "Vocateca" for a link once the repo is live; GitHub's About field doesn't render Markdown links, so keep it plain text and put the `https://vocateca.com` link in the README instead, which already has it.)

## Suggested topics

Pick 5–8; GitHub allows up to 20 but a focused set reads better and surfaces in more relevant searches:

- `swift`
- `macos`
- `transcription`
- `speech-to-text`
- `whisper`
- `mcp` (Model Context Protocol — high-signal tag right now for AI-agent tooling discovery)
- `cli`
- `podcast`

Optional alternates/additions if you want to swap any of the above: `on-device`, `privacy`, `apple-silicon`, `coreml`, `mlx`, `youtube-dl`, `local-first`, `open-core`.

## Notes on naming

The overnight report flags one thing worth confirming before publish: the app's `UpdateChecker.swift` default points at `madevmuc/vocateca` as the update-check repo slug. If the real GitHub owner/repo ends up different (e.g. `m4ma/vocateca`), that slug needs a one-line fix (in both this repo's copy and the app's) so "Check for updates" resolves correctly. See report section 6/7.

## Status

- Local git repo only, single branch (`main`), two commits, **no remote configured**.
- No `gh repo create`, no push, no topic-setting has been run.
- This file and the README are prep for your morning review — go/no-go and any wording edits are yours before anything goes out.
