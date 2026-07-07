import Foundation
import VocatecaCore

// MARK: - sources <subcommand>

/// Subscribe / manage sources. All adds funnel through `WatchlistStore`
/// (dedup by slug, atomic YAML write). Polling after add is opt-in via
/// `--poll` (uses the headless `FeedIngestor`); the running app / `queue run`
/// will otherwise pick up new episodes on its own schedule.
enum SourcesCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let sub = args.subcommand else {
            throw CLIError("sources requires a subcommand (list, add-podcast, add-youtube, add-instagram, add-ytdlp, remove, enable, disable, set, refresh-metadata)", exitCode: 2)
        }
        switch sub {
        case "list":             try listAlias(asJSON: asJSON)
        case "add-podcast":      try await addPodcast(args, asJSON: asJSON)
        case "add-opml":         try await addOPML(args, asJSON: asJSON)
        case "add-youtube":      try await addYouTube(args, asJSON: asJSON)
        case "add-instagram":    try await addInstagram(args, asJSON: asJSON)
        case "add-ytdlp":        try await addYtDlp(args, asJSON: asJSON)
        case "remove":           try remove(args, asJSON: asJSON)
        case "enable":           try setEnabled(args, enabled: true, asJSON: asJSON)
        case "disable":          try setEnabled(args, enabled: false, asJSON: asJSON)
        case "set":              try setFields(args, asJSON: asJSON)
        case "refresh-metadata": try await refreshMetadata(args, asJSON: asJSON)
        default:
            throw CLIError("unknown sources subcommand '\(sub)'", exitCode: 2)
        }
    }

    /// `sources list` — alias of `shows`.
    private static func listAlias(asJSON: Bool) throws {
        try runShowsListing(asJSON: asJSON)
    }

    // MARK: - Poll helper

    /// Poll a single show headlessly (opt-in) and return the count of newly
    /// inserted episodes, or nil when polling wasn't requested / not possible.
    ///
    /// Also persists any parsed channel metadata (title/artwork) back to the
    /// watchlist — same metadata-refresh fix as the app's IngestCoordinator, so
    /// a CLI `--poll` also replaces a slug-derived title with the real one.
    private static func pollIfRequested(_ args: ParsedArgs, slug: String) async -> Int? {
        guard args.flags.contains("poll") else { return nil }
        do {
            let wl = try loadWatchlist()
            guard let show = wl.shows.first(where: { $0.slug == slug }) else { return nil }
            let store = try openWritableStore()
            let result = try await FeedIngestor(watchlistURL: Paths.watchlistURL).poll(show: show, store: store)
            persistChannelMetaIfNeeded(result.channelMeta, show: show)
            return result.episodes.count
        } catch {
            Log.warn("CLI: poll-after-add failed", component: "CLI",
                     context: [("slug", slug), ("error", "\(error)")])
            return nil
        }
    }

    /// Persist a poll's parsed channel metadata (title/artwork) to the watchlist.
    /// Mirrors `IngestCoordinator.persistChannelMetaIfNeeded` (VocatecaUI) — CLI
    /// has no UI layer to share it with, so it's duplicated in miniature here.
    /// Never blanks an existing title/artwork: `updateMetadata` only overwrites
    /// non-empty incoming fields, and `customTitle` is left untouched.
    private static func persistChannelMetaIfNeeded(_ meta: RSSManifest.ChannelMeta?, show: Show) {
        guard let meta, (!meta.title.isEmpty || !meta.artworkURL.isEmpty) else { return }
        do {
            let store = try WatchlistStore.load(from: Paths.watchlistURL)
            let refreshed = RefreshedMetadata(
                title: meta.title.isEmpty ? nil : meta.title,
                author: nil,
                artworkURL: meta.artworkURL.isEmpty ? nil : meta.artworkURL,
                handle: nil
            )
            try store.updateMetadata(slug: show.slug, metadata: refreshed, to: Paths.watchlistURL)
            Log.info("CLI: show metadata refreshed from feed", component: "CLI",
                     context: [("slug", show.slug),
                                ("oldTitle", show.title.isEmpty ? "(empty)" : show.title),
                                ("newTitle", meta.title.isEmpty ? "(unchanged)" : meta.title)])
        } catch {
            Log.warn("CLI: failed to persist refreshed show metadata", component: "CLI",
                     context: [("slug", show.slug), ("error", "\(error)")])
        }
    }

    // MARK: - add-podcast

    private static func addPodcast(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let feed = args.subPositional.first else {
            throw CLIError("sources add-podcast requires a <feed-url>", exitCode: 2)
        }
        let title  = args.opts["title"] ?? deriveTitle(fromURL: feed)
        let author = args.opts["author"] ?? ""
        let slug   = WatchlistStore.slugify(title)

        if args.isDryRun {
            emitSuccess(["action": "add-podcast", "slug": slug, "title": title,
                         "feed_url": feed, "dry_run": true],
                        human: "would subscribe to podcast '\(title)' (slug \(slug)) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        try store.addPodcast(feedURL: feed, title: title, author: author, to: Paths.watchlistURL)

        Log.info("CLI: add-podcast", component: "CLI",
                 context: [("slug", slug), ("feed", feed), ("json", "\(asJSON)")])

        let polled = await pollIfRequested(args, slug: slug)
        emitAdd(action: "add-podcast", slug: slug, title: title, polled: polled, asJSON: asJSON)
    }

    // MARK: - add-opml

    /// `sources add-opml <file> [--backfill last-n|since|none] [--n N]
    /// [--since YYYY-MM-DD] [--dry-run] [--json]`
    ///
    /// Bulk-subscribes every feed found in an OPML file via `OPMLImporter`
    /// (which always subscribes with `backfillMode = only_new` — the safe
    /// bulk default). `--backfill` is an *additional*, Pro-gated pass that
    /// widens newly-added shows' initial queue to their back-catalogue;
    /// Free users still get a full subscribe, just without the backfill.
    private static func addOPML(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let path = args.subPositional.first else {
            throw CLIError("sources add-opml requires a <file>", exitCode: 2)
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            throw CLIError("cannot read OPML file: \(error)", exitCode: 2)
        }

        let feeds = OPMLParser.parse(data)

        if args.isDryRun {
            emitSuccess([
                "action": "add-opml", "dry_run": true,
                "would_import": feeds.count,
                "titles": feeds.map { $0.title },
            ], human: "would import \(feeds.count) feed(s) from '\(path)' (dry-run)", asJSON: asJSON)
            return
        }

        let result = OPMLImporter.importFeeds(feeds, into: Paths.watchlistURL)

        Log.info("CLI: add-opml", component: "OPML",
                 context: [("added", "\(result.added.count)"),
                            ("skipped", "\(result.skipped.count)"),
                            ("failed", "\(result.failed.count)"),
                            ("json", "\(asJSON)")])

        var payload: [String: Any] = [
            "action": "add-opml",
            "added": result.added,
            "added_count": result.added.count,
            "skipped": result.skipped,
            "skipped_count": result.skipped.count,
            "failed": result.failed.map { ["title": $0.title, "error": $0.error] },
            "failed_count": result.failed.count,
        ]
        var humanLines = [
            "OPML import: \(result.added.count) added, \(result.skipped.count) skipped, \(result.failed.count) failed",
        ]

        // Optional backfill for the newly-added shows. The CLI is intentionally
        // NOT Pro-gated (see CLICommandCatalog.conventions) — backfill runs for
        // everyone, matching the AddSourceSheet/OPMLImportSection UI, which is
        // Free too.
        if let backfillArg = args.opts["backfill"], backfillArg != "none" {
            let mode: BackfillMode
            switch backfillArg {
            case "last-n": mode = .lastN
            case "since":  mode = .sinceDate
            default:
                throw CLIError("invalid --backfill '\(backfillArg)' (expected last-n|since|none)", exitCode: 2)
            }
            let n     = Int(args.opts["n"] ?? "") ?? 10
            let since = args.opts["since"] ?? ""

            let store = try openWritableStore()
            let wl = try loadWatchlist()
            var totalQueued = 0
            var backfillErrors: [[String: String]] = []

            for slug in result.added {
                guard let show = wl.shows.first(where: { $0.slug == slug }) else { continue }
                do {
                    let pollResult = try await FeedIngestor(watchlistURL: Paths.watchlistURL).poll(show: show, store: store)
                    // OPML-added shows are the main victim of the slug-as-title bug
                    // (title == slug at add time) — persist the real title/artwork
                    // from this same poll's already-fetched feed.
                    persistChannelMetaIfNeeded(pollResult.channelMeta, show: show)
                    let policy = BackfillPolicy(mode: mode, n: n, sinceDate: since, subscribedAt: show.addedAt)
                    let (queued, _) = try store.applyBackfill(showSlug: slug, policy: policy)
                    totalQueued += queued
                } catch {
                    // One feed's poll/backfill failure must not abort the rest of the batch.
                    backfillErrors.append(["slug": slug, "error": "\(error)"])
                    Log.warn("CLI: add-opml backfill failed for show", component: "OPML",
                             context: [("slug", slug), ("error", "\(error)")])
                }
            }

            payload["backfill_queued"] = totalQueued
            if !backfillErrors.isEmpty { payload["backfill_errors"] = backfillErrors }
            humanLines.append("backfill queued: \(totalQueued) episode(s)\(backfillErrors.isEmpty ? "" : " (\(backfillErrors.count) show(s) failed)")")

            Log.info("CLI: add-opml backfill finished", component: "OPML",
                     context: [("queued", "\(totalQueued)"), ("errors", "\(backfillErrors.count)")])
        }

        emitSuccess(payload, human: humanLines.joined(separator: "\n"), asJSON: asJSON)
    }

    // MARK: - add-youtube

    private static func addYouTube(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let input = args.subPositional.first else {
            throw CLIError("sources add-youtube requires a <channel-url-or-id>", exitCode: 2)
        }
        let skipShorts    = args.flags.contains("skip-shorts")
        // `include-videos` is on by default (matches Show.defaultIncludeVideos);
        // there is no CLI opt-out flag currently (mirrors --include-videos being
        // documented as an on-switch only).
        let includeVideos = true
        let language      = args.opts["language"] ?? "Auto"

        // Resolve the channel URL / @handle to a channel ID (accepts a raw ID too).
        let channelID: String
        do {
            channelID = try await YouTubeResolver().resolveChannelID(from: input)
        } catch {
            throw CLIError("could not resolve YouTube channel '\(input)': \(error)")
        }
        let title = args.opts["title"] ?? channelID
        let slug  = WatchlistStore.slugify(title)

        if args.isDryRun {
            emitSuccess(["action": "add-youtube", "slug": slug, "title": title,
                         "channel_id": channelID, "dry_run": true],
                        human: "would subscribe to YouTube channel \(channelID) (slug \(slug)) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        try store.addYouTube(channelID: channelID, title: title, author: args.opts["author"] ?? "",
                             skipShorts: skipShorts, includeVideos: includeVideos,
                             language: language, to: Paths.watchlistURL)

        Log.info("CLI: add-youtube", component: "CLI",
                 context: [("slug", slug), ("channelID", channelID), ("json", "\(asJSON)")])

        let polled = await pollIfRequested(args, slug: slug)
        emitAdd(action: "add-youtube", slug: slug, title: title, polled: polled, asJSON: asJSON)
    }

    // MARK: - add-instagram

    private static func addInstagram(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let handle = args.subPositional.first else {
            throw CLIError("sources add-instagram requires a <handle>", exitCode: 2)
        }
        // Content-type flags: if none given, default to reels + posts (mirrors app defaults).
        var reels   = args.flags.contains("reels")
        var posts   = args.flags.contains("posts")
        let stories = args.flags.contains("stories")
        if !reels && !posts && !stories { reels = true; posts = true }

        let backfillModeArg = args.opts["backfill-mode"] ?? "none"
        // Map the CLI's documented none|recent|all vocabulary to the Show model's
        // raw values (forward|last_n|full — see IGBackfillMode in AddInstagramSheet.swift).
        let backfillMode: String
        switch backfillModeArg {
        case "none":   backfillMode = "forward"
        case "recent": backfillMode = "last_n"
        case "all":    backfillMode = "full"
        default:
            throw CLIError("invalid --backfill-mode '\(backfillModeArg)' (expected none|recent|all)", exitCode: 2)
        }
        let backfillN    = Int(args.opts["backfill-n"] ?? "0") ?? 0
        let normalized   = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let slug         = WatchlistStore.slugify(normalized.lowercased())

        if args.isDryRun {
            emitSuccess(["action": "add-instagram", "slug": slug, "handle": "@\(normalized.lowercased())",
                         "reels": reels, "posts": posts, "stories": stories, "dry_run": true],
                        human: "would subscribe to Instagram @\(normalized.lowercased()) (slug \(slug)) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        let show = try store.addInstagram(handle: handle, reels: reels, posts: posts, stories: stories,
                                          backfillMode: backfillMode, backfillN: backfillN,
                                          to: Paths.watchlistURL)

        Log.info("CLI: add-instagram", component: "CLI",
                 context: [("slug", show.slug), ("handle", show.title), ("json", "\(asJSON)")])

        emitAdd(action: "add-instagram", slug: show.slug, title: show.title, polled: nil, asJSON: asJSON)
    }

    // MARK: - add-ytdlp

    private static func addYtDlp(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let url = args.subPositional.first else {
            throw CLIError("sources add-ytdlp requires a <channel-url>", exitCode: 2)
        }
        let title  = args.opts["title"] ?? deriveTitle(fromURL: url)
        let author = args.opts["author"] ?? ""
        let slug   = WatchlistStore.slugify(title)

        if args.isDryRun {
            emitSuccess(["action": "add-ytdlp", "slug": slug, "title": title,
                         "channel_url": url, "dry_run": true],
                        human: "would subscribe to yt-dlp source '\(title)' (slug \(slug)) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        let show = try store.addYtDlp(channelURL: url, title: title, author: author, to: Paths.watchlistURL)

        Log.info("CLI: add-ytdlp", component: "CLI",
                 context: [("slug", show.slug), ("url", url), ("json", "\(asJSON)")])

        let polled = await pollIfRequested(args, slug: show.slug)
        emitAdd(action: "add-ytdlp", slug: show.slug, title: show.title, polled: polled, asJSON: asJSON)
    }

    // MARK: - remove

    private static func remove(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let slug = args.subPositional.first else {
            throw CLIError("sources remove requires a <slug>", exitCode: 2)
        }
        let keepEpisodes = args.flags.contains("keep-episodes")
        let wl = try loadWatchlist()
        guard wl.shows.contains(where: { $0.slug == slug }) else {
            throw CLIError("no such show '\(slug)'")
        }

        if args.isDryRun {
            emitSuccess(["action": "remove", "slug": slug, "keep_episodes": keepEpisodes, "dry_run": true],
                        human: "would remove '\(slug)'\(keepEpisodes ? " (keeping episodes)" : "") (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        store.remove(slug: slug)
        try store.save(to: Paths.watchlistURL)
        if !keepEpisodes {
            let db = try openWritableStore()
            try db.deleteShow(slug: slug)
        }

        Log.info("CLI: remove-source", component: "CLI",
                 context: [("slug", slug), ("keepEpisodes", "\(keepEpisodes)"), ("json", "\(asJSON)")])

        emitSuccess(["action": "remove", "slug": slug, "keep_episodes": keepEpisodes],
                    human: "removed '\(slug)'\(keepEpisodes ? " (kept episodes)" : "")", asJSON: asJSON)
    }

    // MARK: - enable / disable

    private static func setEnabled(_ args: ParsedArgs, enabled: Bool, asJSON: Bool) throws {
        guard let slug = args.subPositional.first else {
            throw CLIError("sources \(enabled ? "enable" : "disable") requires a <slug>", exitCode: 2)
        }
        let wl = try loadWatchlist()
        guard wl.shows.contains(where: { $0.slug == slug }) else {
            throw CLIError("no such show '\(slug)'")
        }
        if args.isDryRun {
            emitSuccess(["action": enabled ? "enable" : "disable", "slug": slug, "enabled": enabled, "dry_run": true],
                        human: "would \(enabled ? "enable" : "disable") '\(slug)' (dry-run)", asJSON: asJSON)
            return
        }
        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        try store.updateEnabled(slug: slug, enabled: enabled, to: Paths.watchlistURL)

        Log.info("CLI: set-enabled", component: "CLI",
                 context: [("slug", slug), ("enabled", "\(enabled)"), ("json", "\(asJSON)")])

        emitSuccess(["action": enabled ? "enable" : "disable", "slug": slug, "enabled": enabled],
                    human: "\(enabled ? "enabled" : "disabled") '\(slug)'", asJSON: asJSON)
    }

    // MARK: - set (metadata fields)

    private static func setFields(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let slug = args.subPositional.first else {
            throw CLIError("sources set requires a <slug>", exitCode: 2)
        }
        let wl = try loadWatchlist()
        guard wl.shows.contains(where: { $0.slug == slug }) else {
            throw CLIError("no such show '\(slug)'")
        }
        let language = args.opts["language"]
        let author   = args.opts["author"]
        let creator  = args.opts["creator"]
        guard language != nil || author != nil || creator != nil else {
            throw CLIError("sources set requires at least one of --language, --author, --creator", exitCode: 2)
        }

        var changed: [String: Any] = ["slug": slug]
        if let l = language { changed["language"] = l }
        if let a = author   { changed["author"]   = a }
        if let c = creator  { changed["creator"]  = c }

        if args.isDryRun {
            changed["dry_run"] = true
            emitSuccess(changed.merging(["action": "set"]) { a, _ in a },
                        human: "would update '\(slug)' \(changed) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        if let l = language { try store.updateLanguage(slug: slug, language: l, to: Paths.watchlistURL) }
        if let a = author   { try store.updateAuthor(slug: slug, author: a, to: Paths.watchlistURL) }
        if let c = creator  { try store.updateCreator(slug: slug, creator: c, to: Paths.watchlistURL) }

        Log.info("CLI: set-fields", component: "CLI",
                 context: [("slug", slug), ("json", "\(asJSON)")])

        emitSuccess(changed.merging(["action": "set"]) { a, _ in a },
                    human: "updated '\(slug)'", asJSON: asJSON)
    }

    // MARK: - refresh-metadata

    private static func refreshMetadata(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let slug = args.subPositional.first else {
            throw CLIError("sources refresh-metadata requires a <slug>", exitCode: 2)
        }
        let wl = try loadWatchlist()
        guard let show = wl.shows.first(where: { $0.slug == slug }) else {
            throw CLIError("no such show '\(slug)'")
        }
        if args.isDryRun {
            emitSuccess(["action": "refresh-metadata", "slug": slug, "dry_run": true],
                        human: "would re-fetch metadata for '\(slug)' (dry-run)", asJSON: asJSON)
            return
        }
        let metadata: RefreshedMetadata
        do {
            metadata = try await MetadataRefresher.fetch(for: show)
        } catch {
            throw CLIError("metadata refresh failed for '\(slug)': \(error)")
        }
        let store = try WatchlistStore.load(from: Paths.watchlistURL)
        try store.updateMetadata(slug: slug, metadata: metadata, to: Paths.watchlistURL)

        Log.info("CLI: refresh-metadata", component: "CLI",
                 context: [("slug", slug), ("json", "\(asJSON)")])

        emitSuccess([
            "action": "refresh-metadata", "slug": slug,
            "title": metadata.title as Any? ?? NSNull(),
            "author": metadata.author as Any? ?? NSNull(),
            "artwork_url": metadata.artworkURL as Any? ?? NSNull(),
            "handle": metadata.handle as Any? ?? NSNull(),
        ], human: "refreshed metadata for '\(slug)'", asJSON: asJSON)
    }

    // MARK: - Helpers

    private static func emitAdd(action: String, slug: String, title: String, polled: Int?, asJSON: Bool) {
        var payload: [String: Any] = [
            "action": action, "slug": slug, "title": title, "added": true,
            "polled": polled != nil,
        ]
        if let n = polled { payload["new_episodes"] = n }
        let humanTail = polled.map { " (polled: \($0) new)" } ?? ""
        emitSuccess(payload, human: "subscribed '\(title)' (slug \(slug))\(humanTail)", asJSON: asJSON)
    }

    /// Derive a fallback title from a URL's host when `--title` is omitted.
    private static func deriveTitle(fromURL urlString: String) -> String {
        if let host = URL(string: urlString)?.host { return host }
        return urlString
    }
}
