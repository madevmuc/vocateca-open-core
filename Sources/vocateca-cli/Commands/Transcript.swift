import Foundation
import VocatecaCore

// MARK: - transcript <url>

/// Extract a YouTube video's transcript (captions-first, engine fallback)
/// WITHOUT importing/queuing it — contrast with `transcribe`, which
/// imports+queues. Single-video captions-first path lands in Task E.6;
/// engine fallback (E.7), `--save`/`--subscribe` (E.8), and channel/playlist
/// bulk extraction (E.9) are all implemented.
enum TranscriptCommand {

    /// Outcome of `--save`, threaded through to `emit(...)` so `--json`
    /// output reflects what actually happened.
    private struct SaveNote {
        /// Guid of the freshly-imported episode; `nil` when `alreadySaved`
        /// (the engine path imports internally and we don't re-derive it).
        let guid: String?
        /// `true` when the engine-extraction path already persisted this
        /// video to the Library as part of extraction, so `--save` here was
        /// a no-op rather than a fresh import.
        let alreadySaved: Bool
    }

    /// Outcome of `--subscribe`, threaded through to `emit(...)` so
    /// `--json` output reflects what actually happened.
    private struct SubscribeNote {
        let channelID: String
        let slug: String
    }

    static func run(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let url = args.positional.first else {
            throw CLIError("transcript requires a <url>", exitCode: 2)
        }
        let format = args.opts["format"] ?? "txt"
        guard ["md","txt","srt","vtt","csv","json"].contains(format) else {
            throw CLIError("invalid --format '\(format)' (expected md|txt|srt|vtt|csv|json)", exitCode: 2)
        }
        let enginePref: TranscriptionEngine? = args.opts["engine"].flatMap { TranscriptionEngine(rawValue: $0) }
        if let e = args.opts["engine"], enginePref == nil {
            throw CLIError("invalid --engine '\(e)' (expected auto|whisper|qwen|parakeet)", exitCode: 2)
        }
        // Both a bare flag (`--save`) and a valued form (`--save foo`) are
        // checked because ParsedArgs.parse stores unrecognized flags in
        // `flags` only when bare or followed by another `--flag`, and in
        // `opts` when followed by a non-flag token.
        let wantSave = args.flags.contains("save") || args.opts["save"] != nil
        let wantSubscribe = args.flags.contains("subscribe") || args.opts["subscribe"] != nil

        // `transcript` is catalogued `mutating: true` (it can write to the
        // Library and the watchlist) even though a plain extraction with
        // neither flag is a pure read — same blanket-flag precedent as
        // `queue run`. Short-circuit before any network/subprocess work and
        // say plainly which of extract/save/subscribe would actually run.
        if args.isDryRun {
            var would = ["extract \(format) transcript"]
            if wantSave { would.append("save to Library") }
            if wantSubscribe { would.append("subscribe to the channel") }
            emitSuccess(["action": "transcript", "url": url, "format": format,
                         "save": wantSave, "subscribe": wantSubscribe, "dry_run": true],
                        human: "would \(would.joined(separator: " + ")) for '\(url)' (dry-run)", asJSON: asJSON)
            return
        }

        let parsed = try YouTubeURL.parse(url)
        if parsed.kind == .playlist {
            try await runBulk(playlistOrChannelURL: url, format: format, args: args, asJSON: asJSON)
            return
        }
        if [.channelID, .handle, .channelURL].contains(parsed.kind) {
            // Unlike `.playlist` (which only ever parses out of an already-
            // complete `youtube.com/...` URL), `.channelID`/`.handle`/
            // `.channelURL` can come from a bare handle or name with no
            // scheme/host at all (`YouTubeURL.parse`'s netloc-empty branch) —
            // passing the raw `url` straight to `YouTubePlaylistResolver`
            // would fail `URLSafety.safeURL`'s http(s)-scheme check for those
            // inputs. Resolve to a canonical channel id first (same
            // `YouTubeResolver` used by `sources add-youtube`, accepts any of
            // URL/handle/bare-id) and enumerate its `/videos` tab — this also
            // keeps bulk extraction consistent with the rest of the app's
            // channel-video enumeration (excludes Shorts/Live/Playlists tabs).
            let channelID = try await YouTubeResolver().resolveChannelID(from: url)
            let channelURL = YouTubeResolver.channelVideosURL(channelID: channelID)
            try await runBulk(playlistOrChannelURL: channelURL, format: format, args: args, asJSON: asJSON)
            return
        }

        let extracted = try await singleVideo(url: url, format: format, enginePref: enginePref, args: args)

        var save: SaveNote?
        if wantSave {
            if extracted.source == .engine {
                // The engine-fallback path (`engineExtract`, below) already
                // imports the video via `TranscribeCommand.resolveAndImport`
                // as part of extraction — it needs a queued episode to drive
                // the pipeline through. A second import here would just be a
                // slug/guid dedup no-op, so skip it and report "already saved".
                save = SaveNote(guid: nil, alreadySaved: true)
                Log.info("CLI: transcript --save already persisted (engine path)", component: "CLI",
                         context: [("videoID", extracted.videoID)])
            } else {
                let kind = OneOffLinkClassifier.classify(url)
                let saved = try await TranscribeCommand.resolveAndImport(url: url, kind: kind, titleOverride: extracted.title)
                save = SaveNote(guid: saved.guid, alreadySaved: false)
                Log.info("CLI: transcript --save persisted to Library", component: "CLI",
                         context: [("guid", saved.guid), ("videoID", extracted.videoID)])
            }
        }

        var subscribe: SubscribeNote?
        if wantSubscribe {
            guard let channelID = extracted.channelID, !channelID.isEmpty else {
                throw CLIError("--subscribe: could not determine the channel for this video (no channel_id in yt-dlp metadata)")
            }
            let title = extracted.channelHandle ?? extracted.title
            let slug = WatchlistStore.slugify(title)
            let store = try WatchlistStore.load(from: Paths.watchlistURL)
            try store.addYouTube(channelID: channelID, title: title, author: "",
                                 skipShorts: false, includeVideos: true, language: "Auto",
                                 to: Paths.watchlistURL)
            subscribe = SubscribeNote(channelID: channelID, slug: slug)
            Log.info("CLI: transcript --subscribe subscribed channel", component: "CLI",
                     context: [("slug", slug), ("channelID", channelID)])
        }

        try emit(extracted, format: format, args: args, asJSON: asJSON, save: save, subscribe: subscribe)
    }

    private static func singleVideo(url: String, format: String, enginePref: TranscriptionEngine?, args: ParsedArgs) async throws -> ExtractedTranscript {
        if enginePref == nil, let t = try await YouTubeTranscriptService.captions(forVideoURL: url) {
            Log.info("CLI: transcript extracted from captions", component: "CLI",
                     context: [("videoID", t.videoID), ("source", t.source.rawValue)])
            return t
        }
        // no captions, or --engine forced → Task E.7
        return try await engineExtract(url: url, enginePref: enginePref)
    }

    private static func emit(_ t: ExtractedTranscript, format: String, args: ParsedArgs, asJSON: Bool,
                              save: SaveNote?, subscribe: SubscribeNote?) throws {
        let text = YouTubeTranscriptService.render(t, format: format)

        // Fold --save/--subscribe outcomes into the JSON payload so --json
        // stays a complete, machine-parseable record of what happened.
        var extra: [String: Any] = [:]
        if let save {
            extra["saved"] = true
            extra["already_saved"] = save.alreadySaved
            extra["saved_guid"] = save.guid as Any? ?? NSNull()
        }
        if let subscribe {
            extra["subscribed"] = true
            extra["subscribed_slug"] = subscribe.slug
            extra["subscribed_channel_id"] = subscribe.channelID
        }

        if let out = args.opts["out"] {
            let dest = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
            Log.info("CLI: transcript written to file", component: "CLI", context: [("path", dest.path), ("format", format)])
            var payload: [String: Any] = ["action": "transcript", "video_id": t.videoID, "format": format, "source": t.source.rawValue, "out": dest.path]
            for (k, v) in extra { payload[k] = v }
            var human = "wrote \(format) -> \(dest.path)"
            if let save { human += save.alreadySaved ? " (already saved)" : " (saved: \(save.guid ?? ""))" }
            if let subscribe { human += " (subscribed: \(subscribe.slug))" }
            emitSuccess(payload, human: human, asJSON: asJSON)
        } else if asJSON {
            var payload: [String: Any] = ["ok": true, "action": "transcript", "video_id": t.videoID, "format": format,
                                            "source": t.source.rawValue, "channel_id": t.channelID as Any? ?? NSNull(),
                                            "content": text]
            for (k, v) in extra { payload[k] = v }
            print(jsonString(payload))
        } else {
            // Human mode without --out prints the raw transcript content to
            // stdout (pipeable) — any save/subscribe side-notes go to stderr
            // instead, so they never corrupt piped output.
            if let save {
                fputs("saved to Library\(save.alreadySaved ? " (already saved)" : save.guid.map { " (guid: \($0))" } ?? "")\n", stderr)
            }
            if let subscribe {
                fputs("subscribed to channel (slug: \(subscribe.slug))\n", stderr)
            }
            print(text)
        }
    }

    /// Local-engine transcript extraction fallback (no usable captions, or
    /// `--engine` forced a specific engine).
    ///
    /// Reuses the same in-process machinery as `transcribe --start`:
    /// `TranscribeCommand.resolveAndImport` to register the one-off link,
    /// then `QueueDrive.drain` to run it through the real pipeline. The
    /// resulting `.srt` sidecar (forced on for this one-off, regardless of
    /// the user's persisted setting) is read back and reconstructed into an
    /// `ExtractedTranscript`.
    private static func engineExtract(url: String, enginePref: TranscriptionEngine?) async throws -> ExtractedTranscript {
        let kind = OneOffLinkClassifier.classify(url)
        guard kind == .youtube else { throw CLIError("transcript --engine currently supports YouTube URLs only") }

        Log.info("CLI: transcript engine-path started", component: "CLI",
                 context: [("url", url), ("engine", enginePref?.rawValue ?? "auto")])

        // Force save_srt for this one-off so we have a sidecar to read segments
        // back from, regardless of the user's persisted setting; restore afterward.
        let settingsURL = Paths.settingsURL
        let original = try SettingsStore.load(from: settingsURL, persistDefaultOnMissing: false)
        if !original.saveSrt {
            var forced = original; forced.saveSrt = true
            try SettingsStore.save(forced, to: settingsURL)
        }
        defer {
            if !original.saveSrt {
                do { try SettingsStore.save(original, to: settingsURL) }
                catch { Log.warn("CLI: transcript engine-path failed to restore save_srt setting", component: "CLI",
                                  context: [("error", "\(error)")]) }
            }
        }

        let result = try await TranscribeCommand.resolveAndImport(url: url, kind: kind, titleOverride: nil)
        let store = try openWritableStore()
        _ = await QueueDrive.drain(store: store, restrictToSlugs: [result.showSlug],
                                    stopWhenGuidDone: result.guid, enginePref: enginePref, streamProgress: false)

        guard let reader = try StateReader.openProductionForReading(),
              let ep = try reader.allEpisodes().first(where: { $0.guid == result.guid }),
              let mdURL = LibraryIndex.resolveTranscriptURL(for: ep, outputRoot: Paths.userDataDir()) else {
            throw CLIError("engine transcription finished but no transcript was found for '\(result.guid)'")
        }
        let srtURL = mdURL.deletingPathExtension().appendingPathExtension("srt")
        guard let srt = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw CLIError("engine transcription finished but no .srt sidecar was written for '\(result.guid)'")
        }
        let videoID = (try? YouTubeURL.parse(url).value) ?? result.guid
        // KNOWN GAP: `MediaURLResolver`/`ResolvedMedia` (which `resolveAndImport`
        // resolves through for the engine path) doesn't carry channelID/
        // channelHandle, so this path can't populate them the way the
        // captions path (`YouTubeTranscriptService.captions`, which fetches
        // full yt-dlp video metadata) does. Net effect: `--subscribe` on a
        // video that fell through to the engine path throws "could not
        // determine the channel" (E.8) rather than subscribing — fixing that
        // requires widening `ResolvedMedia`, out of scope here.
        return ExtractedTranscript(videoID: videoID, title: ep.title, channelID: nil, channelHandle: nil,
                                    segments: TranscriptFormat.srtToSegments(srt), language: ep.detectedLanguage,
                                    source: .engine)
    }

    // MARK: - Bulk extraction (playlist/channel)

    /// Bulk transcript extraction over a playlist/channel URL. Resolves the
    /// URL to its flat list of videos (Phase C's `YouTubePlaylistResolver`),
    /// then runs each video through the exact same single-video extraction
    /// path (`singleVideo`, above — captions-first, `--engine` fallback) so
    /// bulk behaves identically to `transcript <video-url>` per entry. A
    /// per-entry failure is logged and reflected in the failed/succeeded
    /// counts — it does not abort the rest of the batch.
    private static func runBulk(playlistOrChannelURL url: String, format: String, args: ParsedArgs, asJSON: Bool) async throws {
        let enginePref: TranscriptionEngine? = args.opts["engine"].flatMap { TranscriptionEngine(rawValue: $0) }
        let entries = try await YouTubePlaylistResolver.entries(forURL: url)
        if entries.isEmpty { throw CLIError("no videos found for '\(url)'") }

        Log.info("CLI: transcript bulk extraction started", component: "CLI",
                 context: [("url", url), ("count", "\(entries.count)")])

        var results: [(entry: PlaylistEntry, transcript: ExtractedTranscript?, error: String?)] = []
        for entry in entries {
            do {
                let t = try await singleVideo(url: entry.url, format: format, enginePref: enginePref, args: args)
                results.append((entry, t, nil))
            } catch {
                results.append((entry, nil, "\(error)"))
                Log.warn("CLI: transcript bulk extraction failed for one entry", component: "CLI",
                         context: [("videoID", entry.videoID), ("error", "\(error)")])
            }
        }

        let succeeded = results.filter { $0.transcript != nil }.count
        let failed = results.count - succeeded
        Log.info("CLI: transcript bulk extraction finished", component: "CLI",
                 context: [("url", url), ("count", "\(results.count)"), ("succeeded", "\(succeeded)"), ("failed", "\(failed)")])

        if let outDir = args.opts["out"] {
            let dir = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // `entry.videoID` comes straight from yt-dlp's flat-playlist JSON
            // (`YouTubePlaylistResolver.map`), unvalidated — `appendingPathComponent`
            // does not collapse `..`/`/`, so a crafted id could otherwise escape
            // `dir`. Mirror the branch's videoID charset bar
            // (`YouTubePlayerHTML.sanitizedVideoID`) and refuse to write anything
            // that doesn't match it, counting it as a failed entry instead.
            var writeFailures = 0
            for (entry, t, _) in results {
                guard let t else { continue }
                guard entry.videoID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                    writeFailures += 1
                    Log.warn("CLI: transcript bulk extraction skipped writing unsafe videoID", component: "CLI",
                             context: [("videoID", entry.videoID)])
                    continue
                }
                let dest = dir.appendingPathComponent("\(entry.videoID).\(format)")
                try YouTubeTranscriptService.render(t, format: format).write(to: dest, atomically: true, encoding: .utf8)
            }
            let succeeded = succeeded - writeFailures
            let failed = failed + writeFailures
            emitSuccess(["action": "transcript-bulk", "url": url, "count": results.count,
                         "succeeded": succeeded, "failed": failed, "out_dir": dir.path],
                        human: "extracted \(succeeded)/\(results.count) video(s) -> \(dir.path)\(failed > 0 ? " (\(failed) failed)" : "")",
                        asJSON: asJSON)
            return
        }

        if asJSON {
            let rows = results.map { (entry, t, err) -> [String: Any] in
                guard let t else { return ["video_id": entry.videoID, "title": entry.title, "error": err ?? "unknown"] }
                return ["video_id": t.videoID, "title": entry.title, "source": t.source.rawValue,
                        "content": YouTubeTranscriptService.render(t, format: format)]
            }
            print(jsonString(rows))
        } else {
            for (entry, t, err) in results {
                print("=== \(entry.videoID): \(entry.title) ===")
                if let t { print(YouTubeTranscriptService.render(t, format: format)) }
                else { print("(failed: \(err ?? "unknown"))") }
                print("")
            }
            if failed > 0 {
                fputs("\(failed)/\(results.count) video(s) failed\n", stderr)
            }
        }
    }
}
