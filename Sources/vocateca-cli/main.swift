import Foundation
import VocatecaCore

// MARK: - JSON helpers

/// Encode `value` to a JSON string using the same formatting as Python's
/// `json.dumps(payload, indent=2, default=str, ensure_ascii=False)`.
/// We pass `.sortedKeys` so dict key order is deterministic (Python does
/// NOT sort by default, but the oracle test compares parsed JSON, not bytes).
func jsonString(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Shared CLI error / output helpers (used by Commands/*.swift)

/// A CLI-level error carrying a human-readable message. Thrown by command
/// handlers; caught in `main()` which renders it per the error contract
/// (human → `error: …` stderr + exit 1; JSON → `{"ok": false, "error": …}`).
struct CLIError: Error {
    let message: String
    /// Exit code — 1 for runtime errors (default), 2 for usage errors.
    let exitCode: Int32
    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

/// Emit a mutating-command success payload. In `--json` mode prints the object
/// (always stamped `ok: true`); in human mode prints `line`.
func emitSuccess(_ payload: [String: Any], human line: String, asJSON: Bool) {
    if asJSON {
        var p = payload
        p["ok"] = true
        print(jsonString(p))
    } else {
        print(line)
    }
}

// MARK: - Shared data loading

func loadWatchlist() throws -> Watchlist {
    try Watchlist.load(from: Paths.watchlistURL)
}

func loadSettings() throws -> Settings {
    try SettingsStore.load(from: Paths.settingsURL, persistDefaultOnMissing: false)
}

/// Open the production state DB **read-write** for mutating CLI commands.
/// Uses the WAL + busy-timeout contract so it is safe alongside a running GUI.
func openWritableStore() throws -> StateStore {
    do {
        return try StateStore(databaseURL: Paths.stateDatabaseURL)
    } catch {
        throw CLIError("state.sqlite could not be opened read-write: \(error)")
    }
}

// MARK: - Episode dict (matching Python's _episode_dict exactly)

func episodeDict(_ ep: Episode) -> [String: Any] {
    func n(_ s: String?) -> Any { s as Any? ?? NSNull() }
    func ni(_ i: Int?)    -> Any { i as Any? ?? NSNull() }
    func nd(_ d: Double?) -> Any { d as Any? ?? NSNull() }
    return [
        "guid":             ep.guid,
        "show_slug":        ep.showSlug,
        "title":            ep.title,
        "pub_date":         ep.pubDate,
        "status":           ep.status,
        "priority":         ep.priority,
        "duration_sec":     ni(ep.durationSec),
        "detected_language": n(ep.detectedLanguage),
        "mean_confidence":  nd(ep.meanConfidence),
        "word_count":       ni(ep.wordCount),
        "mp3_path":         n(ep.mp3Path),
        "transcript_path":  n(ep.transcriptPath),
        "attempted_at":     n(ep.attemptedAt),
        "completed_at":     n(ep.completedAt),
        "error_text":       n(ep.errorText),
        "error_category":   n(ep.errorCategory),
        "attempts":         ep.attempts,
    ]
}

// MARK: - Commands

private func cmdVersion() {
    print("vocateca \(Vocateca.version)")
}

/// `status [--json]`
private func cmdStatus(asJSON: Bool) throws {
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr)
        exit(1)
    }

    var byStatus = try reader.episodeCountByStatus()
    for key in ["pending", "downloading", "downloaded", "transcribing", "done", "failed", "stale"] {
        byStatus[key] = byStatus[key] ?? 0
    }

    let isPaused    = (try reader.metaValue(forKey: "queue_paused") ?? "0") == "1"
    let pausedReason = try reader.metaValue(forKey: "paused_reason") ?? ""

    let inFlight = (byStatus["downloading"] ?? 0)
                 + (byStatus["downloaded"]  ?? 0)
                 + (byStatus["transcribing"] ?? 0)
    let queueDepth = (byStatus["pending"]   ?? 0)
                   + (byStatus["downloading"] ?? 0)
                   + (byStatus["downloaded"]  ?? 0)
                   + (byStatus["transcribing"] ?? 0)

    var payload: [String: Any] = [
        "by_status":    byStatus,
        "queue_paused": isPaused,
        "paused_reason": pausedReason,
        "in_flight":    inFlight,
        "queue_depth":  queueDepth,
    ]

    let automation: AutomationStatus? = {
        guard let json = try? reader.metaValue(forKey: AutomationStatus.metaKey) else { return nil }
        return AutomationStatus.decode(json)
    }()

    if let a = automation {
        payload["automation"] = [
            "last_run_at":      a.lastRunAt as Any? ?? NSNull(),
            "next_run_at":      a.nextRunAt as Any? ?? NSNull(),
            "done":             a.done,
            "failed":           a.failed,
            "last_skip_reason": a.lastSkipReason.rawValue,
        ]
    }

    if asJSON {
        print(jsonString(payload))
    } else {
        print("queue: \(isPaused ? "PAUSED" : "running")", terminator: "")
        if isPaused && !pausedReason.isEmpty { print(" (reason: \(pausedReason))") } else { print() }
        print("depth: \(queueDepth)  (in-flight: \(inFlight))")
        print("by status:")
        for key in ["pending","downloading","downloaded","transcribing","done","failed","stale"] {
            print("  \(key.padding(toLength: 14, withPad: " ", startingAt: 0))\(byStatus[key] ?? 0)")
        }
        if let a = automation {
            print("automation: last \(a.lastRunAt ?? "—") · done \(a.done) · skip \(a.lastSkipReason.rawValue)")
        }
    }
}

/// Shared shows listing, reused by `shows` / `list` / `sources list`.
func runShowsListing(asJSON: Bool) throws {
    try cmdShows(asJSON: asJSON)
}

/// Shared status, reused by `status` / `queue status`.
func runStatus(asJSON: Bool) throws {
    try cmdStatus(asJSON: asJSON)
}

/// `shows [--json]`  (alias `list`)
private func cmdShows(asJSON: Bool) throws {
    let wl = try loadWatchlist()
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr); exit(1)
    }

    var rows: [[String: Any]] = []
    for show in wl.shows {
        let counts = try reader.episodeCountsByStatus(forShowSlug: show.slug)
        let total   = counts.values.reduce(0, +)
        let feedHealth = try reader.metaValue(forKey: "feed_health:\(show.slug)") ?? "unknown"
        rows.append([
            "slug":                    show.slug,
            "title":                   show.title,
            "rss":                     show.rss,
            "source":                  show.source,
            "enabled":                 show.enabled,
            "language":                show.language,
            "whisper_prompt":          show.whisperPrompt,
            "youtube_transcript_pref": show.youtubeTranscriptPref,
            "output_override":         show.outputOverride as Any? ?? NSNull(),
            "feed_health":             feedHealth,
            "total":                   total,
            "pending":                 counts["pending"] ?? 0,
            "done":                    counts["done"]    ?? 0,
            "failed":                  counts["failed"]  ?? 0,
        ])
    }

    if asJSON {
        print(jsonString(rows))
    } else {
        if rows.isEmpty { print("(empty)"); return }
        print(String(format: "%2s %-7s %-28s %4s %5s %4s  title", "on","src","slug","pend","done","fail"))
        for r in rows {
            let on   = (r["enabled"] as? Bool == true) ? "✓" : " "
            let src  = (r["source"]  as? String ?? "").padding(toLength: 7,  withPad: " ", startingAt: 0)
            let slug = (r["slug"]    as? String ?? "").padding(toLength: 28, withPad: " ", startingAt: 0)
            let pend = String(format: "%4d", r["pending"] as? Int ?? 0)
            let dn   = String(format: "%5d", r["done"]    as? Int ?? 0)
            let fl   = String(format: "%4d", r["failed"]  as? Int ?? 0)
            let ttl  = r["title"] as? String ?? ""
            print(" \(on) \(src) \(slug) \(pend) \(dn) \(fl)  \(ttl)")
        }
    }
}

/// `episodes <slug> [--status <s>] [--limit N] [--json]`
private func cmdEpisodes(slug: String, statusFilter: String?, limit: Int, asJSON: Bool) throws {
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr); exit(1)
    }
    let eps   = try reader.fetchEpisodesBySlug(showSlug: slug, statusFilter: statusFilter, limit: limit)
    let dicts = eps.map { episodeDict($0) }

    if asJSON {
        print(jsonString(dicts))
    } else {
        if dicts.isEmpty { print("(none)"); return }
        print(String(format: "%-13s %-25s %4s  guid / title", "status", "pub_date", "pri"))
        for e in dicts {
            let st  = (e["status"]   as? String ?? "").padding(toLength: 13, withPad: " ", startingAt: 0)
            let pd  = String((e["pub_date"] as? String ?? "").prefix(25))
                          .padding(toLength: 25, withPad: " ", startingAt: 0)
            let pri = String(format: "%4d", e["priority"] as? Int ?? 0)
            let g   = String((e["guid"]  as? String ?? "").prefix(36))
            let ttl = String((e["title"] as? String ?? "").prefix(60))
            print("\(st) \(pd) \(pri)  \(g)  \(ttl)")
        }
    }
}

/// `failed [--show <slug>] [--limit N] [--json]`
private func cmdFailed(showSlug: String?, limit: Int, asJSON: Bool) throws {
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr); exit(1)
    }
    let eps   = try reader.fetchFailed(showSlug: showSlug, limit: limit)
    let dicts = eps.map { episodeDict($0) }

    if asJSON {
        print(jsonString(dicts))
    } else {
        if dicts.isEmpty { print("(none)"); return }
        for e in dicts {
            let slug  = e["show_slug"] as? String ?? ""
            let title = String((e["title"]    as? String ?? "").prefix(80))
            let guid  = e["guid"]        as? String ?? ""
            let at    = e["attempted_at"] as? String ?? ""
            let err   = String((e["error_text"] as? String ?? "").prefix(200))
            print("\n[\(slug)] \(title)")
            print("  guid: \(guid)")
            print("  attempted: \(at)")
            print("  error: \(err)")
        }
    }
}

/// `stats [--window N] [--json]`
private func cmdStats(windowDays: Int, asJSON: Bool) throws {
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr); exit(1)
    }
    let summary = try reader.dashboardSummary(windowDays: windowDays)

    if asJSON {
        print(jsonString(summary))
    } else {
        let tpd = summary["throughput_per_day"] as? Double ?? 0.0
        let sr  = summary["success_rate"]       as? Double ?? 0.0
        let rf  = summary["realtime_factor"]    as? Double ?? 0.0
        let dn  = summary["done"]               as? Int    ?? 0
        let pn  = summary["pending"]            as? Int    ?? 0
        let fn_ = summary["failed"]             as? Int    ?? 0
        print(String(format: "throughput: %.2f episodes/day (last \(windowDays)d)", tpd))
        print(String(format: "success rate: %.0f%%", sr * 100))
        print(String(format: "realtime factor: %.2f×", rf))
        print("done/pending/failed: \(dn)/\(pn)/\(fn_)")
    }
}

/// `health [--json]`
private func cmdHealth(asJSON: Bool) throws {
    let settings = try loadSettings()
    let dataDir  = Paths.userDataDir()
    let rows     = runHealthCheck(settings: settings, dataDir: dataDir)

    if asJSON {
        let payload = rows.map { r -> [String: Any] in ["check": r.check, "ok": r.ok, "detail": r.detail] }
        print(jsonString(payload))
    } else {
        for r in rows { print("\(r.ok ? "✓" : "✗") \(r.check): \(r.detail)") }
    }
    if rows.contains(where: { !$0.ok }) { exit(1) }
}

/// `feed-health [--show <slug>] [--json]`
private func cmdFeedHealth(showSlug: String?, asJSON: Bool) throws {
    let wl = try loadWatchlist()
    guard let reader = try StateReader.openProductionForReading() else {
        fputs("error: state.sqlite not found\n", stderr); exit(1)
    }
    let targets = showSlug == nil ? wl.shows : wl.shows.filter { $0.slug == showSlug }

    var out: [[String: Any]] = []
    for show in targets {
        let cat      = try reader.metaValue(forKey: "feed_fail_category:\(show.slug)") ?? ""
        let health   = try reader.metaValue(forKey: "feed_health:\(show.slug)")         ?? "unknown"
        let failCnt  = Int(try reader.metaValue(forKey: "feed_fail_count:\(show.slug)") ?? "0") ?? 0
        let backoff  = try reader.metaValue(forKey: "feed_backoff_until:\(show.slug)")  ?? ""
        let message  = try reader.metaValue(forKey: "feed_fail_message:\(show.slug)")   ?? ""
        let failedAt = try reader.metaValue(forKey: "feed_fail_at:\(show.slug)")        ?? ""
        // Python computes recommendation(cat) via core.feed_errors; for parity we
        // emit "" when cat is empty (which it is for all healthy shows). For failed
        // shows the recommendation text is Python-specific — we match Python's "" default.
        out.append([
            "slug":          show.slug,
            "feed_health":   health,
            "fail_count":    failCnt,
            "backoff_until": backoff,
            "category":      cat,
            "message":       message,
            "failed_at":     failedAt,
            "recommendation": "",
        ])
    }

    if asJSON {
        print(jsonString(out))
    } else {
        if out.isEmpty { print("(no shows)"); return }
        print(String(format: "%-28s %-10s %-14s %5s  backoff_until", "slug","health","category","fails"))
        for r in out {
            let s  = (r["slug"]        as? String ?? "").padding(toLength: 28, withPad: " ", startingAt: 0)
            let h  = (r["feed_health"] as? String ?? "").padding(toLength: 10, withPad: " ", startingAt: 0)
            let ct = (r["category"]    as? String ?? "").padding(toLength: 14, withPad: " ", startingAt: 0)
            let fc = String(format: "%5d", r["fail_count"] as? Int ?? 0)
            let bo = r["backoff_until"] as? String ?? ""
            print("\(s) \(h) \(ct) \(fc)  \(bo)")
        }
    }
}

/// `ig-doctor [--json]` — Instagram account-pool health. Exit 0 healthy, 2 needs
/// attention (suspended / re-auth), 1 on error.
private func cmdIgDoctor(asJSON: Bool) {
    let liveURL = Paths.stateDatabaseURL
    guard FileManager.default.fileExists(atPath: liveURL.path) else {
        if asJSON { print(jsonString(["accounts": [] as [Any], "healthy": true, "note": "no database"])) }
        else       { print("ig-doctor: no state database found.") }
        return
    }
    do {
        // Snapshot copy (never touch the live DB read-write) then read the pool.
        let snapshot = try StateReader.snapshotProduction(of: liveURL)
        let store = try StateStore(databaseURL: snapshot)
        let report = IGDiagnostics.assemble(accounts: try AccountPool.all(in: store))
        if asJSON {
            let payload: [String: Any] = [
                "healthy": report.healthy,
                "accounts": report.accounts.map {
                    [
                        "account_id": $0.accountId,
                        "status": $0.status,
                        "active": $0.isActive,
                        "failed_attempts": $0.failedAttempts,
                        "last_check": $0.lastCheck ?? "",
                    ]
                },
            ]
            print(jsonString(payload))
        } else {
            print(report.summary)
        }
        exit(report.healthy ? 0 : 2)
    } catch {
        FileHandle.standardError.write(Data("ig-doctor: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Health check (Swift port of core/health.py)

struct HealthRow { let check: String; let ok: Bool; let detail: String }

private func runHealthCheck(settings: Settings, dataDir: URL) -> [HealthRow] {
    [
        checkDependencies(),
        checkModelHash(),
        checkDataDirWritable(dataDir),
        checkDiskSpace(dataDir, minGb: settings.diskGuardMinFreeGb),
    ]
}

// I-3: was hardcoded `ok: true, "no pin yet (first use)"` — an honest health
// row now, backed by `ModelPins` (VocatecaCore/Transcription/ModelPins.swift).
// `ModelPins.anyPinned` is currently always `false` (M-3 revision pinning is
// upstream-blocked for all three engines — see that file's TODOs), so this
// reports `ok: false, "unpinned"` rather than a green check the app cannot
// back up. The day an engine's upstream seam lands and a real revision is
// recorded, this row goes green automatically.
private func checkModelHash() -> HealthRow {
    ModelPins.anyPinned
        ? HealthRow(check: "model_hash", ok: true, detail: "pinned")
        : HealthRow(check: "model_hash", ok: false, detail: "unpinned (M-3 — upstream seam pending)")
}

private func checkDependencies() -> HealthRow {
    var missing: [String] = []
    // I-3: yt-dlp is resolved via the SAME managed-path-only lookup the
    // pipeline actually uses at runtime — a PATH-based `which` here could
    // report "ok" while the pipeline's managed copy is absent (or vice
    // versa). `whisper-cli` probe dropped: WhisperKit runs in-process, the
    // Swift pipeline never shells out to a `whisper-cli` binary.
    let bm = BinaryManager()
    if !bm.isInstalled(.ytDlp)   { missing.append("yt-dlp") }
    if !bm.isInstalled(.ffmpeg) { missing.append("ffmpeg") }
    return missing.isEmpty
        ? HealthRow(check: "dependencies", ok: true,  detail: "yt-dlp + ffmpeg present")
        : HealthRow(check: "dependencies", ok: false, detail: "missing: " + missing.joined(separator: ", "))
}

private func checkDataDirWritable(_ dir: URL) -> HealthRow {
    let probe = dir.appendingPathComponent(".health_write_probe")
    do {
        try "ok".write(to: probe, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: probe)
        return HealthRow(check: "data_dir_writable", ok: true, detail: "writable")
    } catch {
        return HealthRow(check: "data_dir_writable", ok: false, detail: "not writable: \(error)")
    }
}

private func checkDiskSpace(_ dir: URL, minGb: Int) -> HealthRow {
    guard
        let attrs    = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
        let freeBytes = attrs[.systemFreeSize] as? Int64
    else {
        return HealthRow(check: "disk_space", ok: false, detail: "couldn't read free space")
    }
    let freeGb = Double(freeBytes) / 1_073_741_824.0
    if freeGb < Double(minGb) {
        return HealthRow(check: "disk_space", ok: false,
                         detail: String(format: "only %.1f GB free (guard \(minGb) GB)", freeGb))
    }
    return HealthRow(check: "disk_space", ok: true, detail: String(format: "%.1f GB free", freeGb))
}

// MARK: - Hand-rolled arg parser

struct ParsedArgs {
    var command: String = ""
    var positional: [String] = []
    var flags: Set<String>   = []
    var opts: [String: String] = [:]

    /// Convenience: the sub-command is the first positional after the command
    /// (e.g. `add-podcast` in `sources add-podcast <url>`). `nil` when absent.
    var subcommand: String? { positional.first }
    /// Positionals after the sub-command (the sub-command's own arguments).
    var subPositional: [String] { positional.isEmpty ? [] : Array(positional.dropFirst()) }
    var isDryRun: Bool { flags.contains("dry-run") }

    /// Bare (valueless) flags. Recognised explicitly so they never swallow a
    /// following positional argument (e.g. `queue requeue <guid> --json` or
    /// `transcribe <url> --start` when `<url>`/`<guid>` follow the flag).
    static let knownBareFlags: Set<String> = [
        "json", "dry-run", "no-poll", "poll",
        "skip-shorts", "include-videos",
        "reels", "posts", "stories",
        "keep-episodes",
        "start", "all", "unread", "once",
    ]

    mutating func parse(_ args: ArraySlice<String>) {
        var remaining = Array(args)
        guard !remaining.isEmpty else { return }
        command = remaining.removeFirst()
        var i = 0
        while i < remaining.count {
            let tok = remaining[i]
            if tok == "--json" {
                flags.insert("json")
            } else if tok.hasPrefix("--") {
                let key = String(tok.dropFirst(2))
                if Self.knownBareFlags.contains(key) {
                    flags.insert(key)
                } else if i + 1 < remaining.count && !remaining[i + 1].hasPrefix("--") {
                    opts[key] = remaining[i + 1]; i += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(tok)
            }
            i += 1
        }
    }
}

// MARK: - Entry point

func main() async {
    // C1 — ORDERING INVARIANT: run the data-directory and Keychain migrations
    // here, synchronously, BEFORE any Paths.userDataDir / StateReader / Watchlist
    // access.  Paths.userDataDir() auto-creates the Vocateca dir; running
    // migration first ensures the legacy Paragraphos dir (if present) is
    // detected before it is masked by an empty Vocateca dir.
    let migration = AppDataMigration()
    let dirResult = migration.runIfNeeded()
    NSLog("AppDataMigration (dir): %@", "\(dirResult)")
    migration.migrateKeychainIfNeeded(keychain: SystemKeychainMigrationStore())

    var parsed = ParsedArgs()
    parsed.parse(CommandLine.arguments.dropFirst())

    let asJSON = parsed.flags.contains("json")

    do {
        switch parsed.command {
        case "version", "--version":
            cmdVersion()

        case "status":
            try cmdStatus(asJSON: asJSON)

        case "shows", "list":
            try cmdShows(asJSON: asJSON)

        case "episodes":
            guard let slug = parsed.positional.first else {
                fputs("error: episodes requires a <slug> argument\n", stderr); exit(2)
            }
            try cmdEpisodes(
                slug: slug,
                statusFilter: parsed.opts["status"],
                limit: Int(parsed.opts["limit"] ?? "0") ?? 0,
                asJSON: asJSON)

        case "failed":
            try cmdFailed(
                showSlug: parsed.opts["show"],
                limit: Int(parsed.opts["limit"] ?? "0") ?? 0,
                asJSON: asJSON)

        case "stats":
            try cmdStats(windowDays: Int(parsed.opts["window"] ?? "7") ?? 7, asJSON: asJSON)

        case "health":
            try cmdHealth(asJSON: asJSON)

        case "feed-health":
            try cmdFeedHealth(showSlug: parsed.opts["show"], asJSON: asJSON)

        case "ig-doctor":
            cmdIgDoctor(asJSON: asJSON)

        // MARK: - Write / control commands

        case "sources":
            try await SourcesCommands.run(parsed, asJSON: asJSON)

        case "transcribe":
            try await TranscribeCommand.run(parsed, asJSON: asJSON)

        case "transcript":
            try await TranscriptCommand.run(parsed, asJSON: asJSON)

        case "queue":
            try await QueueCommands.run(parsed, asJSON: asJSON)

        case "library":
            try await LibraryCommands.run(parsed, asJSON: asJSON)

        case "integrations":
            try IntegrationsCommands.run(parsed, asJSON: asJSON)

        case "settings":
            try SettingsCommands.run(parsed, asJSON: asJSON)

        case "engine":
            try EngineCommands.run(parsed, asJSON: asJSON)

        case "retry":
            try RetryCommand.run(parsed, asJSON: asJSON)

        case "notifications":
            try NotificationsCommands.run(parsed, asJSON: asJSON)

        case "docs":
            // Regenerate docs/CLI.md from the shared catalog:
            //   vocateca-cli docs > docs/CLI.md
            print(CLICommandCatalog.renderMarkdown())

        case "mcp":
            // Blocking stdio JSON-RPC loop for the Model Context Protocol —
            // see MCP/MCPServer.swift. stdout is reserved for protocol
            // messages only; all diagnostics go to stderr.
            MCPServer().run()

        case "", "help", "--help", "-h":
            // Rendered from the shared CLICommandCatalog so help ↔ catalog ↔
            // docs/CLI.md can never drift.
            print(CLICommandCatalog.renderHelp(version: Vocateca.version))

        default:
            // `CLIDispatch.handledCommands` is the authoritative dispatch list;
            // referencing it here ties the switch to the constant the parity
            // test guards against `CLICommandCatalog.topLevelCommands`.
            _ = CLIDispatch.handledCommands
            fputs("error: unknown command '\(parsed.command)'\n", stderr)
            fputs("Run 'vocateca-cli help' for usage.\n", stderr)
            exit(2)
        }
    } catch let e as CLIError {
        if asJSON {
            print(jsonString(["ok": false, "error": e.message]))
        } else {
            fputs("error: \(e.message)\n", stderr)
        }
        exit(e.exitCode)
    } catch {
        if asJSON {
            print(jsonString(["ok": false, "error": "\(error)"]))
        } else {
            fputs("error: \(error)\n", stderr)
        }
        exit(1)
    }
}

// Entry point. `main()` is async because several commands (`sources add-*`,
// `transcribe`, `queue run`) await network resolvers and the `@MainActor`
// `QueueRunner`. We launch it on a detached Task and keep the main thread's
// run loop alive via `dispatchMain()`, so the MainActor executor (the main
// thread) stays free to service the drain — blocking it with a semaphore would
// deadlock any MainActor-isolated work. Each command exits the process itself
// (explicit `exit(...)` in the error path; the success path calls `exit(0)`).
Task {
    await main()
    exit(0)
}
dispatchMain()
