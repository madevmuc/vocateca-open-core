import Foundation
import VocatecaCore

// MARK: - library <subcommand>

enum LibraryCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let sub = args.subcommand else {
            throw CLIError("library requires a subcommand: search <query> | export <guid> | delete <guid> | send <guid>", exitCode: 2)
        }
        switch sub {
        case "search": try search(args, asJSON: asJSON)
        case "export": try export(args, asJSON: asJSON)
        case "delete": try delete(args, asJSON: asJSON)
        case "send": try await send(args, asJSON: asJSON)
        default:
            throw CLIError("unknown library subcommand '\(sub)'", exitCode: 2)
        }
    }

    /// Resolve the library output root (app data dir — the same root the writer
    /// used, NOT settings.outputRoot which is only an export mirror).
    private static func outputRoot() -> URL {
        Paths.userDataDir()
    }

    private static func openReader() throws -> StateReader {
        guard let reader = try StateReader.openProductionForReading() else {
            throw CLIError("state.sqlite not found")
        }
        return reader
    }

    // MARK: - search

    private static func search(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let query = args.subPositional.first else {
            throw CLIError("library search requires a <query>", exitCode: 2)
        }
        let showFilter = args.opts["show"]
        let limit = Int(args.opts["limit"] ?? "") ?? 0

        let reader = try openReader()
        let episodes = try reader.allEpisodes()
        let filtered = showFilter == nil ? episodes : episodes.filter { $0.showSlug == showFilter }
        let index = LibraryIndex(outputRoot: outputRoot(), episodes: filtered)
        let indexed = index.indexedEpisodes()
        var results = LibrarySearch().search(query, in: indexed)
        if limit > 0 { results = Array(results.prefix(limit)) }

        // Show-title lookup for output.
        let wl = try? loadWatchlist()
        func showTitle(_ slug: String) -> String {
            wl?.shows.first(where: { $0.slug == slug })?.title ?? slug
        }

        if asJSON {
            let rows = results.map { r -> [String: Any] in
                let ep = r.indexedEpisode.episode
                return [
                    "guid": ep.guid,
                    "show_slug": ep.showSlug,
                    "show_title": showTitle(ep.showSlug),
                    "title": ep.title,
                    "score": r.score,
                    "transcript_path": r.indexedEpisode.transcriptURL?.path as Any? ?? NSNull(),
                ]
            }
            print(jsonString(rows))
        } else {
            if results.isEmpty { print("(no matches)"); return }
            for r in results {
                let ep = r.indexedEpisode.episode
                print(String(format: "%.2f  [%@] %@", r.score, ep.showSlug, ep.title))
                print("      guid: \(ep.guid)")
                if let p = r.indexedEpisode.transcriptURL?.path { print("      \(p)") }
            }
        }
    }

    // MARK: - export

    private static func export(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let guid = args.subPositional.first else {
            throw CLIError("library export requires a <guid>", exitCode: 2)
        }
        let format = args.opts["format"] ?? "md"
        guard ["md", "txt", "html", "srt"].contains(format) else {
            throw CLIError("invalid --format '\(format)' (expected md|txt|html|srt)", exitCode: 2)
        }

        let reader = try openReader()
        let episodes = try reader.allEpisodes()
        guard let ep = episodes.first(where: { $0.guid == guid }) else {
            throw CLIError("no such episode '\(guid)'")
        }
        guard let mdURL = LibraryIndex.resolveTranscriptURL(for: ep, outputRoot: outputRoot()) else {
            throw CLIError("no transcript on disk for '\(guid)' (not transcribed yet?)")
        }

        // Determine the source file for the requested format.
        let sourceURL: URL
        var synthesizedText: String? = nil
        switch format {
        case "md":
            sourceURL = mdURL
        case "srt":
            sourceURL = mdURL.deletingPathExtension().appendingPathExtension("srt")
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw CLIError("no .srt sidecar for '\(guid)' (enable save_srt at transcribe time)")
            }
        case "html":
            sourceURL = mdURL.deletingPathExtension().appendingPathExtension("html")
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw CLIError("no .html sidecar for '\(guid)' (enable save_html at transcribe time)")
            }
        case "txt":
            sourceURL = mdURL   // synthesized from the .md body
            let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
            synthesizedText = TranscriptFormat.txtFromMarkdown(md)
        default:
            sourceURL = mdURL
        }

        // If no --out, just report the resolved source path (or synthesized note).
        guard let out = args.opts["out"] else {
            if asJSON {
                print(jsonString([
                    "ok": true, "action": "library-export", "guid": guid, "format": format,
                    "source_path": sourceURL.path,
                    "synthesized": synthesizedText != nil,
                ]))
            } else {
                print(sourceURL.path)
            }
            return
        }

        // Resolve --out to a concrete file path (file or directory).
        let destURL = resolveOutPath(out, format: format, sourceURL: sourceURL, guid: guid)

        if args.isDryRun {
            emitSuccess([
                "action": "library-export", "guid": guid, "format": format,
                "source_path": sourceURL.path, "dest_path": destURL.path, "dry_run": true,
            ], human: "would export \(format) -> \(destURL.path) (dry-run)", asJSON: asJSON)
            return
        }

        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let text = synthesizedText {
            try text.write(to: destURL, atomically: true, encoding: .utf8)
        } else {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        Log.info("CLI: library export", component: "CLI",
                 context: [("guid", guid), ("format", format), ("dest", destURL.path), ("json", "\(asJSON)")])

        emitSuccess([
            "action": "library-export", "guid": guid, "format": format,
            "source_path": sourceURL.path, "dest_path": destURL.path,
        ], human: "exported \(format) -> \(destURL.path)", asJSON: asJSON)
    }

    /// Resolve `--out` (which may be a directory or a file path) to a concrete
    /// destination file with the correct extension.
    private static func resolveOutPath(_ out: String, format: String, sourceURL: URL, guid: String) -> URL {
        let expanded = (out as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        let looksLikeDir = out.hasSuffix("/") || (exists && isDir.boolValue)
        if looksLikeDir {
            let base = sourceURL.deletingPathExtension().lastPathComponent
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("\(base).\(format)")
        }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - delete

    private static func delete(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let guid = args.subPositional.first else {
            throw CLIError("library delete requires a <guid>", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "library-delete", "guid": guid, "dry_run": true],
                        human: "would clear transcript + skip '\(guid)' (dry-run)", asJSON: asJSON)
            return
        }
        let store = try openWritableStore()
        let priorPath = try store.clearTranscriptAndSkip(guid: guid)
        if let p = priorPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: p))
        }

        Log.info("CLI: library delete", component: "CLI",
                 context: [("guid", guid), ("removedPath", priorPath ?? "none"), ("json", "\(asJSON)")])

        emitSuccess([
            "action": "library-delete", "guid": guid,
            "removed_path": priorPath as Any? ?? NSNull(),
        ], human: "cleared transcript for '\(guid)'\(priorPath.map { " (removed \($0))" } ?? "")", asJSON: asJSON)
    }

    // MARK: - send

    private static func send(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let guid = args.subPositional.first else {
            throw CLIError("library send requires a <guid>", exitCode: 2)
        }
        guard let to = args.opts["to"], !to.isEmpty else {
            throw CLIError("library send requires --to <target> (supported: notion)", exitCode: 2)
        }
        guard let target = IntegrationTarget(rawValue: to) else {
            throw CLIError("unsupported --to target '\(to)' (supported: notion)", exitCode: 2)
        }

        if args.flags.contains("dry-run") {
            emitSuccess([
                "dry_run": true, "target": target.rawValue, "guid": guid,
            ], human: "would send '\(guid)' -> \(target.rawValue) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try openWritableStore()
        let settings = try loadSettings()
        let outcome = await IntegrationSender().send(
            episodeGuid: guid,
            to: target,
            store: store,
            secrets: IntegrationSecrets(),
            settings: settings
        )

        if asJSON {
            print(jsonString(["ok": outcome.ok, "message": outcome.message]))
        } else {
            print(outcome.ok ? "sent: \(outcome.message)" : "error: \(outcome.message)")
        }
        if !outcome.ok {
            exit(1)
        }
    }
}
