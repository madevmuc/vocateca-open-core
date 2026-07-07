import Foundation
import VocatecaCore

// MARK: - queue <subcommand>

enum QueueCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let sub = args.subcommand else {
            throw CLIError("queue requires a subcommand: status | pause | resume | enqueue | requeue | remove | stop-after | run", exitCode: 2)
        }
        switch sub {
        case "status":     try statusAlias(asJSON: asJSON)
        case "pause":      try setPaused(true, args: args, asJSON: asJSON)
        case "resume":     try setPaused(false, args: args, asJSON: asJSON)
        case "enqueue":    try enqueue(args, asJSON: asJSON)
        case "requeue":    try requeue(args, asJSON: asJSON)
        case "remove":     try remove(args, asJSON: asJSON)
        case "stop-after": try stopAfter(args, asJSON: asJSON)
        case "run":        try await runDrain(args, asJSON: asJSON)
        default:
            throw CLIError("unknown queue subcommand '\(sub)'", exitCode: 2)
        }
    }

    private static func statusAlias(asJSON: Bool) throws {
        try runStatus(asJSON: asJSON)
    }

    // MARK: - pause / resume

    private static func setPaused(_ paused: Bool, args: ParsedArgs, asJSON: Bool) throws {
        if args.isDryRun {
            emitSuccess(["action": paused ? "pause" : "resume", "queue_paused": paused, "dry_run": true],
                        human: "would \(paused ? "pause" : "resume") the queue (dry-run)", asJSON: asJSON)
            return
        }
        let store = try openWritableStore()
        try store.setMeta(key: "queue_paused", value: paused ? "1" : "0")

        Log.info("CLI: queue \(paused ? "pause" : "resume")", component: "CLI",
                 context: [("queue_paused", "\(paused)"), ("json", "\(asJSON)")])

        emitSuccess(["action": paused ? "pause" : "resume", "queue_paused": paused],
                    human: paused ? "queue paused" : "queue resumed", asJSON: asJSON)
    }

    // MARK: - enqueue (front)

    private static func enqueue(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let guid = args.subPositional.first else {
            throw CLIError("queue enqueue requires a <guid>", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "enqueue", "guid": guid, "dry_run": true],
                        human: "would move '\(guid)' to front of queue (dry-run)", asJSON: asJSON)
            return
        }
        let store = try openWritableStore()
        try store.enqueueFront(guid: guid)

        Log.info("CLI: queue enqueue-front", component: "CLI",
                 context: [("guid", guid), ("json", "\(asJSON)")])

        emitSuccess(["action": "enqueue", "guid": guid],
                    human: "moved '\(guid)' to front of queue", asJSON: asJSON)
    }

    // MARK: - requeue (reset to pending)

    private static func requeue(_ args: ParsedArgs, asJSON: Bool) throws {
        let guids = args.subPositional
        guard !guids.isEmpty else {
            throw CLIError("queue requeue requires at least one <guid>", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "requeue", "guids": guids, "count": guids.count, "dry_run": true],
                        human: "would requeue \(guids.count) episode(s) (dry-run)", asJSON: asJSON)
            return
        }
        let store = try openWritableStore()
        try store.requeue(guids: guids)

        Log.info("CLI: queue requeue", component: "CLI",
                 context: [("count", "\(guids.count)"), ("json", "\(asJSON)")])

        emitSuccess(["action": "requeue", "guids": guids, "count": guids.count],
                    human: "requeued \(guids.count) episode(s)", asJSON: asJSON)
    }

    // MARK: - remove (park as deferred)

    private static func remove(_ args: ParsedArgs, asJSON: Bool) throws {
        let guids = args.subPositional
        guard !guids.isEmpty else {
            throw CLIError("queue remove requires at least one <guid>", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "remove", "guids": guids, "count": guids.count, "dry_run": true],
                        human: "would remove \(guids.count) episode(s) from the queue (dry-run)", asJSON: asJSON)
            return
        }
        let store = try openWritableStore()
        for guid in guids {
            try store.setStatus(guid: guid, .deferred)
        }

        Log.info("CLI: queue remove", component: "CLI",
                 context: [("count", "\(guids.count)"), ("json", "\(asJSON)")])

        emitSuccess(["action": "remove", "guids": guids, "count": guids.count],
                    human: "removed \(guids.count) episode(s) from the queue", asJSON: asJSON)
    }

    // MARK: - stop-after

    private static func stopAfter(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let guid = args.subPositional.first else {
            throw CLIError("queue stop-after requires a <guid>", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "stop-after", "guid": guid, "dry_run": true],
                        human: "would set stop-after '\(guid)' (dry-run)", asJSON: asJSON)
            return
        }
        // Persist the stop-after target as a meta key. A running GUI worker /
        // `queue run` reads `queue_stop_after` and stops once this guid leaves
        // the active set.
        let store = try openWritableStore()
        try store.setMeta(key: "queue_stop_after", value: guid)

        Log.info("CLI: queue stop-after", component: "CLI",
                 context: [("guid", guid), ("json", "\(asJSON)")])

        emitSuccess(["action": "stop-after", "guid": guid],
                    human: "queue will stop after '\(guid)'", asJSON: asJSON)
    }

    // MARK: - run (in-process headless drain)

    private static func runDrain(_ args: ParsedArgs, asJSON: Bool) async throws {
        let once = args.flags.contains("once")
        let max  = Int(args.opts["max"] ?? "") ?? 0
        let slugs: [String]? = args.opts["slugs"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        _ = once  // `once` and natural-drain are equivalent here: the runner stops
                  // when the current backlog empties. `--max`/`--slugs` further bound it.

        if args.isDryRun {
            // Report what would be drained without running any engine.
            let reader = try StateReader.openProductionForReading()
            let all = (try? reader?.allEpisodes()) ?? []
            let active = all.filter { ["pending","downloading","downloaded","transcribing"].contains($0.status) }
            let scoped = slugs.map { s in active.filter { s.contains($0.showSlug) } } ?? active
            emitSuccess([
                "action": "queue-run", "dry_run": true,
                "would_process": scoped.count,
                "slugs": slugs as Any? ?? NSNull(),
                "max": max,
            ], human: "would drain \(scoped.count) pending episode(s) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try openWritableStore()
        let summary = await QueueDrive.drain(
            store: store,
            restrictToSlugs: slugs,
            maxEpisodes: max,
            streamProgress: !asJSON)

        Log.info("CLI: queue run finished", component: "CLI",
                 context: [("processed", "\(summary.processed)"),
                            ("done", "\(summary.done)"),
                            ("failed", "\(summary.failed)"),
                            ("json", "\(asJSON)")])

        if asJSON {
            print(jsonString([
                "ok": true, "processed": summary.processed,
                "done": summary.done, "failed": summary.failed,
            ]))
        } else {
            print("done: processed \(summary.processed) (done \(summary.done), failed \(summary.failed))")
        }
    }
}
