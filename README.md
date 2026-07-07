# Vocateca — Open Core

The open-source core of **[Vocateca](https://vocateca.com)** — a local-first, on-device
podcast / YouTube / Instagram transcription tool for macOS.

This repository contains the parts of Vocateca that are useful on their own and that we
want to develop in the open:

- **`VocatecaCore`** — the domain layer: subscription/source management, the download +
  transcription pipeline, state (SQLite via GRDB), diarization, proper-noun correction,
  integrations (webhooks, Notion, Obsidian export), and diagnostics. Headless, no UI.
- **`VocatecaQwen`** — optional [Qwen3-ASR](https://github.com/soniqo/speech-swift) engine
  (MLX, Apple Silicon, macOS 15+).
- **`VocatecaParakeet`** — optional [Parakeet-TDT](https://github.com/FluidInference/FluidAudio)
  engine (CoreML / Apple Neural Engine).
- **`vocateca-cli`** — a scriptable command-line interface over the core, with `--json`
  output on every command and a built-in **Model Context Protocol** server
  (`vocateca-cli mcp`) so agents/LLMs can drive it.

Everything here runs **entirely on your machine**. Audio never leaves your Mac; models run
on-device (WhisperKit by default, Parakeet or Qwen3-ASR optionally).

## What is *not* here

Vocateca is **open core**. The polished macOS SwiftUI app (Vocateca.app), the Pro
automation runner, and the account / entitlement / billing backend integration are
**proprietary** and are **not** part of this repository. This package builds and runs the
CLI and the transcription core without any of them.

## Requirements

- macOS 15 or newer (Apple Silicon recommended; the Qwen3-ASR engine requires it)
- Swift 6 toolchain (Xcode 16+ or a matching open-source Swift toolchain)
- Runtime tools on `PATH` for downloading media: [`yt-dlp`](https://github.com/yt-dlp/yt-dlp)
  and [`ffmpeg`](https://ffmpeg.org/). (`brew install yt-dlp ffmpeg`)

## Build

```sh
swift build --product vocateca-cli
```

The first build resolves and compiles the ML dependencies (WhisperKit, FluidAudio,
speech-swift), so it takes a while. Subsequent builds are incremental.

## Run

```sh
# Show the queue / status as JSON
swift run vocateca-cli status --json

# List subscribed shows
swift run vocateca-cli shows

# Transcribe a single URL (podcast episode, YouTube video, …)
swift run vocateca-cli transcribe "https://example.com/episode.mp3"

# Full command reference
swift run vocateca-cli help
```

Vocateca stores its data under `~/Library/Application Support/Vocateca` and logs under
`~/Library/Caches/Vocateca/logs`.

### Model Context Protocol (MCP)

`vocateca-cli mcp` speaks JSON-RPC over stdio, exposing the transcription tools to any
MCP-compatible client (Claude, editors, agent frameworks):

```sh
swift run vocateca-cli mcp
```

## Tests

```sh
swift test
```

Some engine tests download models on first run and some are network-gated behind the
`VOCATECA_RUN_NETWORK_TESTS` environment variable.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Trademarks & non-affiliation

"Vocateca" and the Vocateca logo are trademarks of m4ma GmbH. This project is **not**
affiliated with, endorsed by, or sponsored by Apple, Spotify, Apple Podcasts, YouTube /
Google, Instagram / Meta, OpenAI, or any podcast, channel, or creator whose content you
choose to process with it. All product names, logos, and brands are the property of their
respective owners and are used for identification purposes only. You are responsible for
ensuring your use complies with the terms of service and copyright of any content you
transcribe.
