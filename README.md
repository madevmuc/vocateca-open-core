# Vocateca Open Core

**A local-first, on-device transcription engine, CLI, and MCP server for podcasts, YouTube, and Instagram — the open core of [Vocateca](https://vocateca.com).**

Point it at a podcast feed, a YouTube channel, or an Instagram account and it downloads, transcribes, and organizes the output — entirely on your Mac. No audio or transcript ever leaves your machine.

## What's in this repository

This repo contains everything you need to run transcription headlessly, script it, or wire it into an agent — with **no proprietary code and no entitlement checks**:

| Target | What it is |
|---|---|
| [`VocatecaCore`](Sources/VocatecaCore) | The domain layer: subscription/source management, the download + transcription pipeline, state (SQLite via GRDB), speaker diarization, proper-noun correction, integrations (webhooks, Notion, Obsidian export), and diagnostics. Headless — no UI. |
| [`VocatecaQwen`](Sources/VocatecaQwen) | Optional [Qwen3-ASR](https://github.com/soniqo/speech-swift) engine (MLX, Apple Silicon, macOS 15+). |
| [`VocatecaParakeet`](Sources/VocatecaParakeet) | Optional [Parakeet-TDT](https://github.com/FluidInference/FluidAudio) engine (CoreML / Apple Neural Engine). |
| [`vocateca-cli`](Sources/vocateca-cli) | A scriptable command-line interface over the core, with `--json` output on every command, and a built-in **Model Context Protocol** server (`vocateca-cli mcp`) so an AI assistant can drive it directly. |

WhisperKit (Whisper) ships as the default, always-available transcription engine inside `VocatecaCore`; Parakeet and Qwen3-ASR are optional, faster/alternative engines you can select per-show.

## What Vocateca (the app) is

[Vocateca](https://vocateca.com) is a native macOS app built on top of this same core: a polished SwiftUI interface, a scheduled automation daemon for hands-off subscriptions, and an account/entitlement system for the paid Pro tier (auto-download, daily digests, deeper integrations). None of that — the app UI, the automation runner, or the account/billing backend — lives in this repository.

## The open-core model

Vocateca is **open core**, split cleanly along one line: **the engine is open, the product is not.**

- **Open (this repo):** the transcription pipeline, state layer, ASR engine bindings, and the CLI/MCP surface. This is the part where trust matters — you should be able to read exactly how your audio gets processed, verify that nothing phones home, and automate it however you like.
- **Not open:** the macOS app's UI, the Pro automation runner, and the account/entitlement/billing backend. This is the product we sell to fund development.
- **Why split it this way:** the app is what people pay for; the engine and tooling are what let anyone verify our local-first claims, build on top of Vocateca, or run it unattended on a server/agent without ever touching the GUI. The CLI is deliberately **not** Pro-gated — every feature here (webhooks, engine choice, watchlists, retry, notifications) works with no entitlement check at all. The Pro gate lives entirely in the app, not in the engine.

If you're deciding whether something belongs here or in the app: if it's about *how transcription happens*, it's open; if it's about *the packaged product experience or how we get paid*, it's not.

## Features

- **Three on-device ASR engines** — WhisperKit (default), Parakeet-TDT (CoreML/ANE), and Qwen3-ASR (MLX) — selectable per show, no cloud calls.
- **Multi-source ingestion** — podcast RSS feeds, YouTube channels/videos, and Instagram accounts (reels/posts/stories).
- **YouTube transcript extraction** — `vocateca-cli transcript <url>` pulls a video's, playlist's, or channel's transcript captions-first (with local-engine fallback for speaker labels), without importing it into the queue.
- **Full pipeline, not just ASR** — download, transcribe, speaker diarization, proper-noun correction, and structured export (Markdown/SRT/VTT/CSV + sidecar metadata).
- **Integrations** — webhooks (with HMAC signing), Notion export, and Obsidian-flavored frontmatter export.
- **Scriptable by design** — every CLI command supports `--json` for stable, snake_case machine output, and mutating commands support `--dry-run` to preview changes before writing.
- **A real MCP server** — `vocateca-cli mcp` speaks newline-delimited JSON-RPC 2.0 over stdio, so Claude (or any MCP client) can list shows, trigger transcriptions, and read results as tool calls.
- **Self-documenting** — `vocateca-cli docs` renders the full command reference straight from the same catalog that powers `--help` and the MCP tool list, so the docs can't drift from the code.

## Requirements

- macOS 15 or newer (Apple Silicon recommended; the Qwen3-ASR engine requires it)
- Swift 6 toolchain (Xcode 16+, or a matching open-source Swift toolchain)
- Runtime tools on `PATH` for downloading media: [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and [`ffmpeg`](https://ffmpeg.org/) (`brew install yt-dlp ffmpeg`)

## Build

```sh
swift build --product vocateca-cli
```

The first build resolves and compiles the ML dependency graph (WhisperKit, FluidAudio, speech-swift/Qwen3ASR — 1600+ compile steps), so it takes a few minutes. Subsequent builds are incremental.

You can also build the libraries on their own, e.g. for embedding in your own tool:

```sh
swift build --product VocatecaCore
swift build --product VocatecaParakeet
swift build --product VocatecaQwen
```

## Run

```sh
# Full command reference (self-generated from the CLI's own catalog)
swift run vocateca-cli help

# Show queue / status as JSON
swift run vocateca-cli status --json

# List subscribed shows
swift run vocateca-cli shows

# Subscribe to / manage sources (podcast feed, YouTube channel, Instagram account)
swift run vocateca-cli sources

# Transcribe a single URL directly (podcast episode, YouTube video, …)
swift run vocateca-cli transcribe "https://example.com/episode.mp3"

# Inspect or drive the download/transcription queue
swift run vocateca-cli queue

# Browse transcripts already produced
swift run vocateca-cli library

# Health check (dependencies, model pinning, disk space)
swift run vocateca-cli health
```

Top-level commands: `status`, `shows`, `episodes`, `failed`, `stats`, `health`, `feed-health`, `ig-doctor`, `sources`, `transcribe`, `queue`, `library`, `integrations`, `settings`, `engine`, `retry`, `notifications`, `docs`, `mcp`. Every command accepts `--json`; run `vocateca-cli docs` to regenerate the full Markdown reference on demand.

Vocateca stores its data under `~/Library/Application Support/Vocateca` and logs under `~/Library/Caches/Vocateca/logs`.

### Model Context Protocol (MCP)

```sh
swift run vocateca-cli mcp
```

Speaks newline-delimited JSON-RPC 2.0 over stdin/stdout (protocol version `2024-11-05`), exposing the CLI's commands as MCP tools to any compatible client — Claude Desktop, an IDE, or your own agent framework. Tool definitions are generated from the same command catalog as `--help` and `vocateca-cli docs`, so the MCP surface, the CLI help, and the generated docs never drift apart. stdout is reserved strictly for protocol messages; diagnostics go to stderr.

## Tests

```sh
swift test
```

Some engine tests download models on first run; some are network-gated behind the `VOCATECA_RUN_NETWORK_TESTS` environment variable and are skipped by default.

## Local-first & private

Everything in this repository runs **on your machine, offline-capable after model download**. Audio is never uploaded anywhere by this code; transcription happens in-process (WhisperKit) or via on-device CoreML/MLX engines (Parakeet, Qwen3-ASR). There is no telemetry and no phone-home in the open core — the only network calls are the ones you'd expect (fetching feeds/media you subscribed to, and downloading model weights on first use of an engine).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding conventions, and the pull request process. In short: this repo stays headless and local-first — contributions that reintroduce app UI, Pro-gating, or account/billing logic will be redirected, since those live in the proprietary app instead.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Trademarks & non-affiliation

"Vocateca" and the Vocateca logo are trademarks of m4ma GmbH. YouTube, Instagram, and podcast names belong to their respective owners; Vocateca is independent and not affiliated with, endorsed by, or sponsored by Apple, Spotify, Apple Podcasts, YouTube / Google, Instagram / Meta, OpenAI, or any podcast, channel, or creator whose content you choose to process with it. All product names, logos, and brands are the property of their respective owners and are used for identification purposes only. You are responsible for ensuring your use complies with the terms of service and copyright of any content you transcribe.
