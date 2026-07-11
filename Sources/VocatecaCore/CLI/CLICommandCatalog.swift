import Foundation

// MARK: - CLIArgType

/// The value type of a structured CLI argument.
public enum CLIArgType: String, Sendable {
    case string
    case integer
    case boolean
}

// MARK: - CLIArg

/// One structured argument (positional or flag) accepted by a CLI command.
public struct CLIArg: Sendable, Equatable {
    public let name: String
    public let type: CLIArgType
    public let required: Bool
    public let description: String
    /// `true` for `--name value` options; `false` for positional arguments.
    public let isFlag: Bool

    public init(
        name: String,
        type: CLIArgType,
        required: Bool,
        description: String,
        isFlag: Bool
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.isFlag = isFlag
    }
}

// MARK: - CLICommandDoc

/// One documented `vocateca-cli` command (or sub-subcommand).
///
/// This is a *declarative description* of the CLI surface — the single source of
/// truth shared by three consumers so they can never drift:
///   1. the in-app Help tab's CLI reference (`VocatecaUI`),
///   2. the generated `docs/CLI.md` (`CLICommandCatalog.renderMarkdown()`),
///   3. the CLI's own `vocateca-cli help` output.
public struct CLICommandDoc: Sendable, Equatable {
    /// The group heading this command lives under (e.g. "Sources", "Queue").
    public let group: String
    /// The invocation as typed, e.g. `"sources add-podcast <feed-url>"`.
    public let command: String
    /// A one-line human summary.
    public let summary: String
    /// Documented option flags, e.g. `["--title T", "--poll", "--json"]`.
    public let options: [String]
    /// An optional example invocation.
    public let example: String?
    /// Structured positional + flag arguments (superset of `options`, machine-readable).
    public let arguments: [CLIArg]
    /// `true` if this command writes/changes state (subject to `--dry-run`); `false` for pure reads.
    public let mutating: Bool

    public init(
        group: String,
        command: String,
        summary: String,
        options: [String] = [],
        example: String? = nil,
        arguments: [CLIArg] = [],
        mutating: Bool = false
    ) {
        self.group = group
        self.command = command
        self.summary = summary
        self.options = options
        self.example = example
        self.arguments = arguments
        self.mutating = mutating
    }
}

// MARK: - CLICommandCatalog

/// The declarative catalog of every `vocateca-cli` command. Populated from
/// `docs/CLI.md` (which is now generated *from* this catalog, closing the loop).
public enum CLICommandCatalog {

    // MARK: Groups (ordered)

    /// The canonical, ordered list of group headings. `all` entries must use one
    /// of these; `renderMarkdown()` and the Help UI iterate groups in this order.
    public static let groups: [String] = [
        "Read & status",
        "Sources",
        "Transcribe",
        "Queue",
        "Library",
        "Integrations",
        "Settings",
        "Engine",
        "Retry",
        "Notifications",
        "Meta",
    ]

    // MARK: Top-level commands (parity target)

    /// The exact set of top-level command strings the CLI dispatches over
    /// (main.swift's `switch parsed.command`). Used by the drift-guard parity
    /// test against the CLI's `handledCommands` constant. The `list` alias for
    /// `shows` is intentionally excluded — this is the set of primary dispatch
    /// names.
    public static let topLevelCommands: [String] = [
        "version",
        "status",
        "shows",
        "episodes",
        "failed",
        "stats",
        "health",
        "feed-health",
        "ig-doctor",
        "sources",
        "transcribe",
        "queue",
        "library",
        "integrations",
        "settings",
        "engine",
        "retry",
        "notifications",
        "docs",
        "help",
        "mcp",
    ]

    // MARK: Conventions blurb

    /// The shared conventions note (from docs/CLI.md's "Conventions" section).
    /// Rendered once at the top of the docs, the CLI help, and the in-app CLI
    /// reference so the `--json` / `--dry-run` / exit-code contract is stated once.
    public static let conventions: String = """
    Every command supports --json — emit a single stable, snake_case JSON value to \
    stdout (without it, output is human-readable text). Mutating commands accept \
    --dry-run to preview without writing, and print {"ok": true, …} describing what \
    changed. Exit codes: 0 success, 1 runtime error (message on stderr), 2 usage \
    error (unknown command / missing argument); health and ig-doctor use a non-zero \
    exit to signal "needs attention". This surface is intentionally NOT Pro-gated: \
    the CLI exposes every feature (webhooks, auto-download, engine choice, watchlist) \
    without an entitlement check — the Pro gate applies to the GUI, not the automation \
    surface. Every invocation first runs the legacy-Paragraphos → Vocateca data-dir + \
    Keychain migration, exactly like the app.
    """

    // MARK: The catalog

    public static let all: [CLICommandDoc] = [

        // ── Read & status ────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Read & status",
            command: "version",
            summary: "Print the version.",
            options: [],
            arguments: [],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "status",
            summary: "Queue depth, in-flight, by-status counts, paused state + reason.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "shows",
            summary: "Watchlist shows with per-show pending/done/failed counts + feed health. (alias: list)",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "episodes <slug>",
            summary: "Episodes for a show.",
            options: ["--status S", "--limit N", "--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to list episodes for.", isFlag: false),
                CLIArg(name: "status", type: .string, required: false, description: "Filter by episode status.", isFlag: true),
                CLIArg(name: "limit", type: .integer, required: false, description: "Maximum number of episodes to return.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "failed",
            summary: "Failed episodes (cross-show).",
            options: ["--show S", "--limit N", "--json"],
            arguments: [
                CLIArg(name: "show", type: .string, required: false, description: "Limit to one show's slug.", isFlag: true),
                CLIArg(name: "limit", type: .integer, required: false, description: "Maximum number of episodes to return.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "stats",
            summary: "Throughput / realtime-factor / success-rate over N days.",
            options: ["--window N", "--json"],
            arguments: [
                CLIArg(name: "window", type: .integer, required: false, description: "Number of days to compute stats over.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "health",
            summary: "Startup self-check (deps, disk, data dir). Exit 1 if any check fails.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "feed-health",
            summary: "Per-show feed health + backoff state.",
            options: ["--show S", "--json"],
            arguments: [
                CLIArg(name: "show", type: .string, required: false, description: "Limit to one show's slug.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Read & status",
            command: "ig-doctor",
            summary: "Instagram account-pool health. Exit 0 healthy / 2 needs attention.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),

        // ── Sources ──────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Sources",
            command: "sources list",
            summary: "Alias of shows.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources add-podcast <feed-url>",
            summary: "Subscribe to an RSS/podcast feed.",
            options: ["--title T", "--author A", "--poll", "--json"],
            example: "vocateca-cli sources add-podcast https://feeds.example.com/show.xml --json",
            arguments: [
                CLIArg(name: "feed-url", type: .string, required: true, description: "RSS/podcast feed URL to subscribe to.", isFlag: false),
                CLIArg(name: "title", type: .string, required: false, description: "Override the show title.", isFlag: true),
                CLIArg(name: "author", type: .string, required: false, description: "Override the show author.", isFlag: true),
                CLIArg(name: "poll", type: .boolean, required: false, description: "Poll the feed immediately after subscribing.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources add-opml <file>",
            summary: "Bulk-subscribe to podcasts from an OPML file. Optional Pro initial backfill.",
            options: ["--backfill last-n|since|none", "--n N", "--since YYYY-MM-DD", "--dry-run", "--json"],
            example: "vocateca-cli sources add-opml ~/subscriptions.opml --backfill last-n --n 5 --json",
            arguments: [
                CLIArg(name: "file", type: .string, required: true, description: "Path to the OPML file.", isFlag: false),
                CLIArg(name: "backfill", type: .string, required: false, description: "Initial backfill: last-n | since | none (Pro).", isFlag: true),
                CLIArg(name: "n", type: .integer, required: false, description: "Episodes per feed for --backfill last-n.", isFlag: true),
                CLIArg(name: "since", type: .string, required: false, description: "Date (YYYY-MM-DD) for --backfill since.", isFlag: true),
                CLIArg(name: "dry-run", type: .boolean, required: false, description: "Parse + report without subscribing.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources add-youtube <channel-url-or-id>",
            summary: "Subscribe to a YouTube channel (resolves a URL/@handle to a channel ID). Standard videos are always included; --skip-shorts excludes Shorts.",
            options: ["--title T", "--author A", "--skip-shorts", "--language L", "--poll", "--json"],
            arguments: [
                CLIArg(name: "channel-url-or-id", type: .string, required: true, description: "YouTube channel URL, @handle, or channel ID.", isFlag: false),
                CLIArg(name: "title", type: .string, required: false, description: "Override the show title.", isFlag: true),
                CLIArg(name: "author", type: .string, required: false, description: "Override the show author.", isFlag: true),
                CLIArg(name: "skip-shorts", type: .boolean, required: false, description: "Exclude YouTube Shorts from the subscription.", isFlag: true),
                CLIArg(name: "language", type: .string, required: false, description: "Language code for the channel.", isFlag: true),
                CLIArg(name: "poll", type: .boolean, required: false, description: "Poll the channel immediately after subscribing.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources add-instagram <handle>",
            summary: "Subscribe to an Instagram creator (needs a signed-in account in the pool — see ig-doctor). Reels + posts default on (stories off).",
            options: ["--reels", "--posts", "--stories", "--backfill-mode none|recent|all", "--backfill-n N", "--json"],
            arguments: [
                CLIArg(name: "handle", type: .string, required: true, description: "Instagram @handle to subscribe to.", isFlag: false),
                CLIArg(name: "reels", type: .boolean, required: false, description: "Include Reels (default on).", isFlag: true),
                CLIArg(name: "posts", type: .boolean, required: false, description: "Include feed posts (default on).", isFlag: true),
                CLIArg(name: "stories", type: .boolean, required: false, description: "Include Stories (default off).", isFlag: true),
                CLIArg(name: "backfill-mode", type: .string, required: false, description: "Backfill mode: none, recent, or all.", isFlag: true),
                CLIArg(name: "backfill-n", type: .integer, required: false, description: "Number of items to backfill when backfill-mode is recent.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources add-ytdlp <channel-url>",
            summary: "Subscribe to any yt-dlp-supported channel/playlist (SoundCloud, Vimeo, …).",
            options: ["--title T", "--author A", "--poll", "--json"],
            arguments: [
                CLIArg(name: "channel-url", type: .string, required: true, description: "Channel or playlist URL supported by yt-dlp.", isFlag: false),
                CLIArg(name: "title", type: .string, required: false, description: "Override the show title.", isFlag: true),
                CLIArg(name: "author", type: .string, required: false, description: "Override the show author.", isFlag: true),
                CLIArg(name: "poll", type: .boolean, required: false, description: "Poll the source immediately after subscribing.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources remove <slug>",
            summary: "Unsubscribe: remove from watchlist and delete the show's episodes (--keep-episodes keeps episode rows).",
            options: ["--keep-episodes", "--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to unsubscribe.", isFlag: false),
                CLIArg(name: "keep-episodes", type: .boolean, required: false, description: "Keep episode rows instead of deleting them.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources enable <slug>",
            summary: "Re-enable \"monitor for new episodes\" without unsubscribing.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to re-enable monitoring for.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources disable <slug>",
            summary: "Pause \"monitor for new episodes\" without unsubscribing.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to pause monitoring for.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources set <slug>",
            summary: "Update per-show metadata fields (at least one flag required).",
            options: ["--language L", "--author A", "--creator C", "--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to update.", isFlag: false),
                CLIArg(name: "language", type: .string, required: false, description: "New language code.", isFlag: true),
                CLIArg(name: "author", type: .string, required: false, description: "New author.", isFlag: true),
                CLIArg(name: "creator", type: .string, required: false, description: "New creator.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Sources",
            command: "sources refresh-metadata <slug>",
            summary: "Re-fetch name/handle/author/artwork from the source and overwrite (non-empty fields only).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "slug", type: .string, required: true, description: "Show slug to refresh metadata for.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Transcribe ───────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Transcribe",
            command: "transcribe <url>",
            summary: "Import a single link (YouTube, Spotify episode, SoundCloud, Instagram, or any yt-dlp/podcast URL) as a one-off pending episode. Spotify episodes resolve against the show's public RSS. With --start, run the pipeline in-process until it completes.",
            options: ["--title T", "--start", "--engine auto|whisper|qwen", "--json"],
            example: "vocateca-cli transcribe \"https://youtube.com/watch?v=abc123\" --start --engine whisper --json",
            arguments: [
                CLIArg(name: "url", type: .string, required: true, description: "URL of the video/episode to import.", isFlag: false),
                CLIArg(name: "title", type: .string, required: false, description: "Override the episode title.", isFlag: true),
                CLIArg(name: "start", type: .boolean, required: false, description: "Run the pipeline in-process until it completes.", isFlag: true),
                CLIArg(name: "engine", type: .string, required: false, description: "Transcription engine: auto, whisper, or qwen.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Queue ────────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Queue",
            command: "queue status",
            summary: "Alias of status.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue pause",
            summary: "Set the queue_paused meta flag (honored by queue run only).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue resume",
            summary: "Clear the queue_paused meta flag (honored by queue run only).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue enqueue <guid>",
            summary: "Move an episode to the front of the queue (priority bump).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid", type: .string, required: true, description: "Episode guid to bump to the front of the queue.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue requeue <guid…>",
            summary: "Reset episodes to pending (no priority bump).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid…", type: .string, required: true, description: "One or more episode guids to reset to pending.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue remove <guid…>",
            summary: "Park episodes as deferred (removed from the active queue; media/show untouched).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid…", type: .string, required: true, description: "One or more episode guids to park as deferred.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue stop-after <guid>",
            summary: "Write the queue_stop_after meta key; a subsequent queue run stops once this episode leaves the active set.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid", type: .string, required: true, description: "Episode guid after which a subsequent queue run stops.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Queue",
            command: "queue run",
            summary: "Run an in-process headless drain (real download + transcribe + library-write). --once drains the current backlog and exits (the default); --max N stops after N terminal episodes.",
            options: ["--slugs a,b", "--once", "--max N", "--json"],
            example: "vocateca-cli queue run --once --json",
            arguments: [
                CLIArg(name: "slugs", type: .string, required: false, description: "Comma-separated show slugs to restrict the drain to.", isFlag: true),
                CLIArg(name: "once", type: .boolean, required: false, description: "Drain the current backlog and exit (default).", isFlag: true),
                CLIArg(name: "max", type: .integer, required: false, description: "Stop after N terminal episodes.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Library ──────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Library",
            command: "library search <query>",
            summary: "Score-ranked search over transcript titles + bodies. Returns guid, show, title, score, transcript path.",
            options: ["--show S", "--limit N", "--json"],
            example: "vocateca-cli library search \"interest rates\" --limit 5 --json",
            arguments: [
                CLIArg(name: "query", type: .string, required: true, description: "Search query text.", isFlag: false),
                CLIArg(name: "show", type: .string, required: false, description: "Limit search to one show's slug.", isFlag: true),
                CLIArg(name: "limit", type: .integer, required: false, description: "Maximum number of results to return.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Library",
            command: "library export <guid>",
            summary: "Export one transcript. md/srt/html/okf copy the on-disk sidecar; txt is synthesized. Writes to --out (file or dir) or prints the resolved source path.",
            options: ["--format md|txt|html|srt|okf", "--out PATH", "--json"],
            example: "vocateca-cli library export local:ab12cd34 --format srt --out ~/Desktop/ --json",
            arguments: [
                CLIArg(name: "guid", type: .string, required: true, description: "Episode guid to export.", isFlag: false),
                CLIArg(name: "format", type: .string, required: false, description: "Export format: md, txt, html, srt, or okf (okf needs save_okf enabled at transcribe time).", isFlag: true),
                CLIArg(name: "out", type: .string, required: false, description: "Output file or directory path.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Library",
            command: "library delete <guid>",
            summary: "Clear the transcript, mark the episode skipped, and remove the transcript file.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid", type: .string, required: true, description: "Episode guid whose transcript should be deleted.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(group: "Library", command: "library send <guid>",
            summary: "Push one transcript to an integration (currently Notion).",
            options: ["--to notion", "--dry-run", "--json"],
            example: "vocateca-cli library send local:ab12cd34 --to notion --json",
            arguments: [
                CLIArg(name: "guid", type: .string, required: true, description: "Episode guid to send.", isFlag: false),
                CLIArg(name: "to", type: .string, required: true, description: "Integration target: notion.", isFlag: true),
                CLIArg(name: "dry-run", type: .boolean, required: false, description: "Preview without sending.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON.", isFlag: true),
            ], mutating: true),

        // ── Integrations ─────────────────────────────────────────────────────
        CLICommandDoc(group: "Integrations", command: "integrations list",
            summary: "List configured integrations and their enabled/auto-push state.",
            options: ["--json"], arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON.", isFlag: true),
            ], mutating: false),
        CLICommandDoc(group: "Integrations", command: "integrations test",
            summary: "Send a ping/test to an integration to verify credentials.",
            options: ["--to notion", "--json"], arguments: [
                CLIArg(name: "to", type: .string, required: true, description: "Integration target: notion.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON.", isFlag: true),
            ], mutating: false),

        // ── Settings ─────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Settings",
            command: "settings list",
            summary: "All keys with current values and types (~90 keys).",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Settings",
            command: "settings get <key>",
            summary: "One key's value.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "key", type: .string, required: true, description: "Settings key to read.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Settings",
            command: "settings set <key> <value>",
            summary: "Set one key (atomic YAML write; validates the value against the field type). Common keys: transcription_engine, whisper_model, qwen_model, auto_start_queue, save_srt/save_txt/save_html, webhooks_enabled, startup_tab.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "key", type: .string, required: true, description: "Settings key to set.", isFlag: false),
                CLIArg(name: "value", type: .string, required: true, description: "New value for the key (validated against the field's type).", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Engine ───────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Engine",
            command: "engine get",
            summary: "Show the engine preference (auto/whisper/qwen) and the engine this Mac would actually resolve to.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Engine",
            command: "engine set <auto|whisper|qwen>",
            summary: "Set the engine preference (writes transcription_engine).",
            options: ["--json"],
            example: "vocateca-cli engine set qwen --json",
            arguments: [
                CLIArg(name: "engine", type: .string, required: true, description: "Engine preference: auto, whisper, or qwen.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Retry ────────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Retry",
            command: "retry <guid…>",
            summary: "Re-enqueue failed episodes at the front of the queue.",
            options: ["--json"],
            arguments: [
                CLIArg(name: "guid…", type: .string, required: true, description: "One or more failed episode guids to re-enqueue.", isFlag: false),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Retry",
            command: "retry --all",
            summary: "Re-enqueue all failed episodes (optionally one show).",
            options: ["--show S", "--json"],
            example: "vocateca-cli retry --all --show acquired --json",
            arguments: [
                CLIArg(name: "all", type: .boolean, required: true, description: "Re-enqueue every failed episode.", isFlag: true),
                CLIArg(name: "show", type: .string, required: false, description: "Limit to one show's slug.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Notifications ────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Notifications",
            command: "notifications list",
            summary: "In-app notifications (from notifications.sqlite).",
            options: ["--unread", "--limit N", "--json"],
            arguments: [
                CLIArg(name: "unread", type: .boolean, required: false, description: "Only list unread notifications.", isFlag: true),
                CLIArg(name: "limit", type: .integer, required: false, description: "Maximum number of notifications to return.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: false
        ),
        CLICommandDoc(
            group: "Notifications",
            command: "notifications read <id>",
            summary: "Mark one notification read (--all marks all).",
            options: ["--all", "--json"],
            arguments: [
                CLIArg(name: "id", type: .string, required: false, description: "Notification id to mark read (omit when using --all).", isFlag: false),
                CLIArg(name: "all", type: .boolean, required: false, description: "Mark all notifications read.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),
        CLICommandDoc(
            group: "Notifications",
            command: "notifications delete <id>",
            summary: "Delete one notification (--all deletes all).",
            options: ["--all", "--json"],
            arguments: [
                CLIArg(name: "id", type: .string, required: false, description: "Notification id to delete (omit when using --all).", isFlag: false),
                CLIArg(name: "all", type: .boolean, required: false, description: "Delete all notifications.", isFlag: true),
                CLIArg(name: "json", type: .boolean, required: false, description: "Emit JSON instead of human-readable text.", isFlag: true),
            ],
            mutating: true
        ),

        // ── Meta ─────────────────────────────────────────────────────────────
        CLICommandDoc(
            group: "Meta",
            command: "docs",
            summary: "Print docs/CLI.md rendered from this catalog (vocateca-cli docs > docs/CLI.md regenerates it).",
            options: [],
            arguments: [],
            mutating: false
        ),
        CLICommandDoc(
            group: "Meta",
            command: "help",
            summary: "Print the command list (help <command> for details).",
            options: [],
            arguments: [],
            mutating: false
        ),
        CLICommandDoc(
            group: "Meta",
            command: "mcp",
            summary: "Run a minimal MCP (Model Context Protocol) stdio server so an AI assistant can drive the app. Newline-delimited JSON-RPC 2.0 on stdin/stdout; blocks until stdin closes.",
            options: [],
            arguments: [],
            mutating: false
        ),
    ]
}
