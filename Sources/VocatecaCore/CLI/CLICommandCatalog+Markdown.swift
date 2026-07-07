import Foundation

extension CLICommandCatalog {

    /// The static header/intro prose for `docs/CLI.md` (everything above the
    /// generated command tables). Kept as a preamble so the generated doc reads
    /// like the hand-written one.
    public static let markdownPreamble: String = """
    # Vocateca CLI (`vocateca-cli`) — full reference

    `vocateca-cli` is the **headless remote-control surface** for Vocateca. Every user-facing
    action in the GUI has a command here, and **every command supports `--json`** with stable,
    machine-readable output — so an LLM (or any automation) can drive the app end-to-end without
    the GUI.

    The CLI reads and writes the **same** data the app uses (`~/Library/Application
    Support/Vocateca/`): `state.sqlite` (WAL — safe to touch while the app is running),
    `watchlist.yaml`, `settings.yaml`, `notifications.sqlite`. YAML writes are atomic; DB writes
    go through the WAL + busy-timeout contract, so concurrent GUI + CLI access is safe.

    > **This surface is intentionally NOT Pro-gated.** Because this is the owner's own app, the
    > CLI exposes ALL functionality — including Pro-gated features (webhooks, auto-download,
    > engine choice, watchlist) — without an entitlement check. The Pro gate applies to the GUI,
    > not to the automation surface.

    > **Generated file.** This document is generated from `CLICommandCatalog` in `VocatecaCore`.
    > Do not edit by hand — run `vocateca-cli docs > docs/CLI.md` to regenerate it.

    ## Conventions

    - **`--json`** — emit a single JSON value (object or array) to stdout. Without it, output is
      human-readable text. JSON keys are stable snake_case; missing values are `null`.
    - **Exit codes** — `0` success; `1` runtime error (message on stderr); `2` usage error
      (unknown command / missing argument). `health` and `ig-doctor` use `2`/non-zero to signal
      "needs attention" (documented per command).
    - **Errors** — human mode prints `error: …` to stderr; `--json` prints
      `{"ok": false, "error": "…"}` to stdout and sets a non-zero exit code.
    - **Mutating commands** print (or return, with `--json`) `{"ok": true, …}` describing what
      changed. Add `--dry-run` to any mutating command to preview without writing.
    - **Migration invariant** — every invocation first runs the data-dir + Keychain migration
      (legacy Paragraphos → Vocateca) before touching any path, exactly like the GUI.

    Run `vocateca-cli help` for a command list, or `vocateca-cli help <command>` for details.
    """

    /// Worked examples appended to the end of `docs/CLI.md`.
    public static let markdownExamples: String = """
    ## Examples (LLM-driving the app end-to-end)

    ```bash
    # Subscribe to a podcast and immediately transcribe its backlog headlessly
    vocateca-cli sources add-podcast https://feeds.example.com/show.xml --json
    vocateca-cli queue run --once --json

    # One-off transcribe a YouTube video with Whisper, blocking until done
    vocateca-cli transcribe "https://youtube.com/watch?v=abc123" --start --engine whisper --json

    # Switch the engine, then check what this Mac resolves to
    vocateca-cli engine set qwen --json
    vocateca-cli engine get --json

    # Find every episode that mentions a topic and export the top hit as SRT
    vocateca-cli library search "interest rates" --limit 5 --json
    vocateca-cli library export local:ab12cd34 --format srt --out ~/Desktop/ --json

    # Triage failures
    vocateca-cli failed --json
    vocateca-cli retry --all --show acquired --json
    ```
    """

    /// The "drive Vocateca from an AI assistant" (MCP) setup section, appended
    /// to `docs/CLI.md`. `vocateca-cli mcp` speaks the Model Context Protocol
    /// over stdio, exposing every catalog command as a tool.
    public static let markdownMCP: String = """
    ## Connect an AI assistant (MCP)

    `vocateca-cli mcp` runs a minimal [Model Context Protocol](https://modelcontextprotocol.io)
    server over stdio, exposing **every command in this reference as an MCP tool**. Read tools
    return the command's `--json` output; mutating tools accept a `dry_run` argument that maps to
    `--dry-run`, so an assistant can preview a change before committing it.

    Register it in Claude Desktop's `claude_desktop_config.json` (macOS:
    `~/Library/Application Support/Claude/claude_desktop_config.json`) with the **absolute path**
    to the built binary:

    ```json
    {
      "mcpServers": {
        "vocateca": {
          "command": "/absolute/path/to/vocateca-cli",
          "args": ["mcp"]
        }
      }
    }
    ```

    Any MCP-speaking client works the same way — the transport is newline-delimited JSON-RPC 2.0
    on stdin/stdout, and the server blocks until stdin closes. **stdout carries protocol messages
    only**; all diagnostics go to stderr, so it is safe to pipe. The tool surface is generated from
    the same catalog as this document, so it never drifts from the CLI.
    """

    /// Render the full `docs/CLI.md` content from the catalog. Grouped sections,
    /// one Markdown table per group (command · description · options).
    public static func renderMarkdown() -> String {
        var out = markdownPreamble
        out += "\n\n---\n"

        // Group entries in the canonical group order.
        let byGroup = Dictionary(grouping: all, by: \.group)
        for group in groups {
            guard let entries = byGroup[group], !entries.isEmpty else { continue }
            out += "\n## \(group)\n\n"
            out += "| Command | Description | Options |\n"
            out += "|---------|-------------|---------|\n"
            for doc in entries {
                let opts = doc.options.isEmpty
                    ? "—"
                    : doc.options.map { "`\(escapePipe($0))`" }.joined(separator: " ")
                out += "| `\(escapePipe(doc.command))` | \(escapeCell(doc.summary)) | \(opts) |\n"
            }
            // Per-group example callouts, if any.
            let examples = entries.compactMap(\.example)
            if !examples.isEmpty {
                out += "\n"
                for ex in examples {
                    out += "> Example: `\(ex)`\n>\n"
                }
                // Drop the trailing continuation line.
                if out.hasSuffix(">\n") { out.removeLast(2) }
            }
        }

        out += "\n---\n\n"
        out += markdownExamples
        out += "\n\n---\n\n"
        out += markdownMCP
        out += "\n"
        return out
    }

    /// Escape characters that would break a Markdown table cell (`|` and newlines).
    private static func escapeCell(_ s: String) -> String {
        escapePipe(s).replacingOccurrences(of: "\n", with: " ")
    }

    /// Escape a literal `|` so it doesn't terminate a Markdown table cell (GFM
    /// requires this even inside inline code spans).
    private static func escapePipe(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Render the human-readable `vocateca-cli help` command list from the
    /// catalog, grouped, aligned in two columns (command · summary). Used by the
    /// CLI's `help` branch so help ↔ catalog can never drift.
    public static func renderHelp(version: String) -> String {
        var out = "vocateca \(version) — headless remote-control surface\n\n"
        out += "Every command supports --json. Mutating commands support --dry-run.\n"
        out += "This surface is intentionally NOT Pro-gated (see docs/CLI.md).\n"

        let byGroup = Dictionary(grouping: all, by: \.group)

        // Column width = longest command string across all groups (+ padding).
        let width = all.map(\.command.count).max() ?? 0
        let pad = min(width, 34) + 2

        for group in groups {
            guard let entries = byGroup[group], !entries.isEmpty else { continue }
            out += "\n\(group):\n"
            for doc in entries {
                let cmd = doc.command
                let padded = cmd.count < pad
                    ? cmd + String(repeating: " ", count: pad - cmd.count)
                    : cmd + "  "
                out += "  \(padded)\(doc.summary)\n"
                if !doc.options.isEmpty {
                    let optPad = String(repeating: " ", count: pad + 2)
                    out += "\(optPad)\(doc.options.joined(separator: " "))\n"
                }
            }
        }
        out += "\nRun 'vocateca-cli docs' for the full reference (docs/CLI.md).\n"
        return out
    }
}
