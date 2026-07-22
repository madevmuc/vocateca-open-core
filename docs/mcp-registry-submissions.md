# MCP registry & directory submission drafts

> **DRAFT — needs USER approval before any submission (outward-facing).**
> Nothing in this document has been submitted anywhere. No PRs opened, no forms
> posted, no API calls made. Every section below is copy-paste-ready text/JSON
> for a human to review and submit manually (or explicitly authorize an agent
> to submit) — treat every URL, form field description, and UI flow as
> best-effort research current as of 2026-07, since these sites change their
> submission UI without notice. Re-verify the live page before actually
> submitting.

## Context: what we're submitting

- **Server:** `vocateca-cli mcp` — a stdio JSON-RPC 2.0 MCP server bundled into
  the `vocateca-cli` Swift executable, exposing ~46 tools derived from
  `CLICommandCatalog` (subscriptions, queue, transcription, library
  search/export, webhooks, settings, diagnostics).
- **Repo:** https://github.com/madevmuc/vocateca-open-core (Apache-2.0, tag
  `v1.5.0`).
- **Key nuance:** this is a **build-from-source Swift binary**. There is no
  published npm/PyPI/Docker/NuGet package — a user runs
  `swift build -c release --product vocateca-cli` and points their MCP client
  at the resulting binary (see README, "Use Vocateca as a data source for your
  AI assistant"). Every directory below either handles that natively (accepts
  a bare GitHub repo) or requires a small manual workaround; noted per-target.

---

## 0. Official MCP registry (modelcontextprotocol/registry)

Not one of "the other directories" per se, but it's the root of the
ecosystem and several directories below (PulseMCP confirmed explicitly)
ingest from it automatically — so publishing here has second-order reach.

- **What we already produced:** `server.json` at the repo root (this PR/commit).
  It validates against the current schema
  (`https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json`)
  using the **"custom installation path"** pattern: no `packages`/`remotes`
  array (none of the schema's `registryType` values — `npm`, `pypi`, `oci`,
  `nuget`, `cargo`, `mcpb` — represent "clone + `swift build`"), just
  `repository` + `websiteUrl` pointing at the README's build/install section.
  This is a documented, valid pattern in the schema (see the "Server with
  Custom Installation Path" example) and is used by real live entries (e.g.
  desktop-embedded servers) — not a fabrication to fit an ill-suited shape.
- **Namespace:** `io.github.madevmuc/vocateca` — the `io.github.<owner>/*`
  namespace is granted via GitHub OAuth device-flow login as the repo owner
  (`madevmuc`), so no separate DNS/domain proof is needed.
- **Publish flow (NOT run — for the user to execute if/when approved):**
  ```sh
  # one-time: install the registry's official publisher CLI, then:
  mcp-publisher login github        # device-flow: opens github.com/login/device
  mcp-publisher publish             # reads ./server.json, publishes to registry.modelcontextprotocol.io
  ```
- **Status:** manifest drafted and schema-validated only. Not published.

---

## 1. Smithery (smithery.ai)

- **URL:** https://smithery.ai
- **Submission format:** CLI-driven, not a web form. `smithery-ai/cli`
  publishes either a hosted URL or an `.mcpb` bundle under an org/name slug.
- **Exact command to run (once a Smithery account/org exists):**
  ```sh
  smithery mcp publish https://github.com/madevmuc/vocateca-open-core -n madevmuc/vocateca
  ```
  Smithery's registry accepts open submissions of GitHub repos; since we ship
  no bundle/hosted URL, the plain repo URL + `-n madevmuc/vocateca` slug is
  the correct invocation for a source-built stdio server. Verify current CLI
  flags against `smithery-ai/cli`'s README before running — Smithery's CLI
  surface has changed shape more than once.
- **Suggested listing description** (for the Smithery web UI, if it presents
  one after CLI publish, or a `smithery.yaml` if required):
  ```yaml
  name: vocateca
  displayName: Vocateca
  description: >
    Local-first, on-device transcription MCP server for podcasts, YouTube,
    and Instagram. ~46 tools (subscriptions, queue, transcription, library
    search/export, webhooks) over stdio. Apache-2.0, build from source
    (Swift 6, macOS 15+) — no published package.
  homepage: https://github.com/madevmuc/vocateca-open-core
  license: Apache-2.0
  ```
- **Status:** drafted only. No Smithery account action taken.

---

## 2. Glama (glama.ai/mcp/servers)

- **URL:** https://glama.ai/mcp/servers (listing "Add Server" entry point)
- **Submission format:** Glama is primarily a **crawler-based** directory —
  it discovers and indexes public GitHub repos tagged/described as MCP
  servers, then lets the owner claim the listing. The most reliable manual
  path is submitting the repo URL via their "Add Server" flow on the servers
  page; exact form fields weren't confirmed by static fetch (page is
  JS-rendered) — a human should open the page and confirm the field set
  before submitting.
- **What to submit:**
  - Repository URL: `https://github.com/madevmuc/vocateca-open-core`
  - Suggested one-line description: `Local-first, on-device podcast/YouTube/Instagram transcription — ~46 MCP tools over stdio.`
  - License: Apache-2.0
  - Note in the "installation" field (if present): "Build from source — `swift build -c release --product vocateca-cli`, then run `vocateca-cli mcp`. See README §Use Vocateca as a data source for your AI assistant."
- **Status:** drafted only. Not submitted; not claimed.

---

## 3. PulseMCP (pulsemcp.com)

- **URL:** https://www.pulsemcp.com/submit
- **Submission format:** confirmed via their own submit page — **PulseMCP
  ingests from the Official MCP Registry daily and processes weekly.** Direct
  quote from their submit page: "We ingest entries from the Official MCP
  Registry daily and process them weekly. If it has been a week since you
  published there, or want to make other adjustments to your listing on
  pulsemcp.com, please email us at **hello@pulsemcp.com**."
  The submit form itself also accepts a URL directly ("Can be a GitHub
  repository, a subfolder of a repository, or a standalone website.").
- **Practical implication:** if/when the user approves publishing
  `server.json` to the official registry (§0), **no separate PulseMCP
  submission is needed** — it should appear within about a week. This
  section is kept only as a manual-fallback draft.
- **Manual fallback submission (if the official-registry route is skipped
  or is too slow):**
  - URL field: `https://github.com/madevmuc/vocateca-open-core`
  - Contact for listing adjustments: `hello@pulsemcp.com` (verified from
    their own page — not a guess)
- **Status:** drafted only. No email sent, no form submitted.

---

## 4. mcp.so

- **URL:** https://mcp.so/submit (also reachable via the "Submit" button in
  the site nav, and as a GitHub-issue-based flow on their repo)
- **Submission format:** per their own submit page, submissions are
  **GitHub-issue based** and currently support **public GitHub MCP servers
  only** (a good fit — no package required). Two paths: fill the web form at
  `/submit`, or open an issue directly on their GitHub repo.
- **Exact text to submit:**
  - Name: `Vocateca`
  - GitHub URL: `https://github.com/madevmuc/vocateca-open-core`
  - Description:
    ```
    Local-first, on-device transcription MCP server for podcasts, YouTube,
    and Instagram, built in Swift. Exposes ~46 tools (subscriptions, queue,
    transcription, library search/export, webhooks, diagnostics) over
    stdio JSON-RPC 2.0 (protocol 2024-11-05). No audio or transcript ever
    leaves the machine. Apache-2.0, build from source (`swift build -c
    release --product vocateca-cli`, then `vocateca-cli mcp`).
    ```
  - Connection info: `command: /absolute/path/to/vocateca-cli`, `args: ["mcp"]` (stdio)
  - License: Apache-2.0
  - Platform: macOS 15+ (Apple Silicon recommended)
- **Status:** drafted only. No form submitted, no issue opened.

---

## 5. `punkpeye/awesome-mcp-servers` — ready-to-paste PR

- **Target file:** `README.md` in
  https://github.com/punkpeye/awesome-mcp-servers
- **Category:** their **"Podcasts"** section is the closest existing
  category (transcription-of-podcasts is the primary use case; YouTube/IG are
  secondary sources into the same pipeline). "Speech-to-Text" is a reasonable
  alternate if a maintainer prefers that framing — flagging the choice rather
  than guessing silently.
- **Legend note:** their emoji legend
  (🐍 Python, 📇 TS/JS, 🏎️ Go, 🦀 Rust, #️⃣ C#, ☕ Java, 🌊 C/C++, 💎 Ruby, plus
  ☁️ cloud / 🏠 local / 📟 embedded / 🍎 macOS / 🪟 Windows / 🐧 Linux / 🎖️
  official) has **no Swift marker** — so the entry below omits a language
  emoji and uses only scope + OS emoji, consistent with how other
  language-less entries in that list are formatted.
- **Placement rule (from their `CONTRIBUTING.md`):** entries must stay in
  alphabetical order within the category — "vocateca" sorts after most
  existing entries; place it alphabetically at PR time, not assumed here.
- **Exact README line to add:**
  ```markdown
  - [madevmuc/vocateca-open-core](https://github.com/madevmuc/vocateca-open-core) 🏠 🍎 - Local-first, on-device transcription MCP server for podcasts, YouTube, and Instagram — ~46 tools over stdio, build from source, Apache-2.0.
  ```
- **PR title (per their `CONTRIBUTING.md` convention):**
  ```
  Add vocateca-open-core to Podcasts
  ```
  (Their contribution guide additionally states: "If you are an automated
  agent, we have a streamlined process for merging agent PRs. Just add
  `🤖🤖🤖` to the end of the PR title to opt-in." — **not** appended here
  since this submission, if made, should go through the user, not an
  unattended agent merge fast-track.)
- **PR description (ready to paste):**
  ```markdown
  Adds Vocateca — a local-first, on-device MCP server (Swift, macOS 15+,
  Apache-2.0) that turns podcast/YouTube/Instagram subscriptions and a
  transcript library into ~46 MCP tools over stdio JSON-RPC 2.0. No
  published package; build from source per the README.

  Repo: https://github.com/madevmuc/vocateca-open-core
  ```
- **Status:** drafted only. No PR opened, no fork made.

---

## Summary table

| Target | Mechanism | Package needed? | Action taken |
|---|---|---|---|
| Official MCP registry | `server.json` + `mcp-publisher` CLI | No (custom-install pattern) | `server.json` drafted + schema-validated. Not published. |
| Smithery | `smithery mcp publish` CLI | No (repo URL accepted) | Command + `smithery.yaml` drafted. Not run. |
| Glama | Web "Add Server" / crawler + claim | No | Fields drafted. Not submitted. |
| PulseMCP | Auto-ingest from official registry, or manual form | No | Drafted; likely auto-covered by §0. Not submitted. |
| mcp.so | Web form or GitHub issue | No | Fields drafted. Not submitted. |
| awesome-mcp-servers | GitHub PR to README.md | No | PR title/body/diff line drafted. Not opened. |

All six items above remain **drafts pending explicit user approval** —
nothing outward-facing has been sent.
