import Foundation
import VocatecaCore

// MARK: - transcribe <url>

/// One-off transcribe of a single link (not subscribed). The link kind is
/// auto-classified; Spotify episodes are resolved against the show's public RSS
/// feed. With `--start`, the pipeline is run in-process until this episode
/// completes.
enum TranscribeCommand {

    static func run(_ args: ParsedArgs, asJSON: Bool) async throws {
        guard let url = args.positional.first else {
            throw CLIError("transcribe requires a <url>", exitCode: 2)
        }
        let start = args.flags.contains("start")
        let titleOverride = args.opts["title"]
        let enginePref: TranscriptionEngine? = args.opts["engine"].flatMap { TranscriptionEngine(rawValue: $0) }
        if let e = args.opts["engine"], enginePref == nil {
            throw CLIError("invalid --engine '\(e)' (expected auto|whisper|qwen)", exitCode: 2)
        }

        let kind = OneOffLinkClassifier.classify(url)

        if args.isDryRun {
            emitSuccess([
                "action": "transcribe", "url": url, "kind": kind.rawValue,
                "start": start, "dry_run": true,
            ], human: "would import one-off \(kind.rawValue) link (start: \(start)) (dry-run)", asJSON: asJSON)
            return
        }

        // Resolve + import (async — network + subprocess), returns the IngestResult.
        let result = try await resolveAndImport(url: url, kind: kind, titleOverride: titleOverride)

        Log.info("CLI: transcribe (one-off import)", component: "CLI",
                 context: [("guid", result.guid), ("kind", kind.rawValue),
                            ("start", "\(start)"), ("json", "\(asJSON)")])

        // Optionally drive the in-process drain until this episode completes.
        if start {
            let store = try openWritableStore()
            _ = await QueueDrive.drain(
                store: store,
                restrictToSlugs: [result.showSlug],
                stopWhenGuidDone: result.guid,
                enginePref: enginePref,
                streamProgress: !asJSON)
        }

        // Re-read the final status.
        var finalStatus = "pending"
        if let reader = try? StateReader.openProductionForReading(),
           let episodes = try? reader.allEpisodes(),
           let ep = episodes.first(where: { $0.guid == result.guid }) {
            finalStatus = ep.status
        }

        emitSuccess([
            "action": "transcribe", "guid": result.guid, "kind": kind.rawValue,
            "title": result.fileURL.lastPathComponent, "status": finalStatus,
            "started": start,
        ], human: "imported \(kind.rawValue) as \(result.guid) (status: \(finalStatus))", asJSON: asJSON)
    }

    // MARK: - Resolve + import

    static func resolveAndImport(url: String, kind: OneOffLinkKind, titleOverride: String?) async throws -> IngestResult {
        let store = try openWritableStore()
        let ingest = LocalIngestService(store: store, watchlistURL: Paths.watchlistURL)

        switch kind {
        case .spotify:
            let outcome = await SpotifyEpisodeResolver().resolve(url)
            switch outcome {
            case let .matched(showName, episodeTitle, itemTitle, audioURL, _, artworkURL):
                let slug = WatchlistStore.slugify(showName)
                let resolvedTitle = titleOverride ?? (episodeTitle.isEmpty ? itemTitle : episodeTitle)
                return try ingest.importURL(
                    title: resolvedTitle,
                    webpageURL: audioURL,
                    showSlug: slug,
                    showTitle: showName,
                    artworkURL: artworkURL,
                    author: showName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : showName,
                    // Matched to the show's public podcast feed → classify as podcast.
                    source: "podcast")
            case let .showLink(showName):
                throw CLIError("that Spotify link is a show, not an episode ('\(showName)') — subscribe with 'sources add-podcast' instead")
            case let .episodeNotMatched(showName, _):
                throw CLIError("couldn't match that Spotify episode in '\(showName)'s public feed")
            case let .noPublicFeed(showName):
                throw CLIError("'\(showName)' has no public RSS feed (Spotify-exclusive)")
            case let .failed(message):
                throw CLIError("Spotify resolve failed: \(message)")
            }

        default:
            // YouTube / generic / podcast / instagram → resolve via yt-dlp metadata.
            let resolved: ResolvedMedia
            do {
                resolved = try await MediaURLResolver().resolve(url)
            } catch {
                throw CLIError("could not resolve '\(url)': \(error)")
            }
            let showTitle = resolved.uploader.isEmpty ? (resolved.title.isEmpty ? "One-off" : resolved.title) : resolved.uploader
            let slug = WatchlistStore.slugify(showTitle)
            let webpageURL = resolved.webpageURL.isEmpty ? url : resolved.webpageURL
            // Classify the one-off by its detected link kind (N4): youtube/instagram/
            // podcast get their tab; anything else (generic web) → "other".
            let source: String
            switch kind {
            case .youtube:   source = "youtube"
            case .instagram: source = "instagram"
            case .podcast:   source = "podcast"
            case .spotify, .generic: source = "other"
            }
            return try ingest.importURL(
                title: titleOverride ?? (resolved.title.isEmpty ? webpageURL : resolved.title),
                webpageURL: webpageURL,
                showSlug: slug,
                showTitle: showTitle,
                artworkURL: resolved.thumbnail,
                author: resolved.uploader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : resolved.uploader,
                source: source)
        }
    }
}
