import Foundation

/// Persists an already-extracted YouTube transcript (from
/// `YouTubeTranscriptService.captions`, i.e. no local ASR run) directly
/// into the library: registers the episode row, writes the `.md` (+
/// enabled sidecars), and marks it `done` — with **no** queue/pipeline
/// involvement, since there is nothing left to transcribe.
///
/// This is deliberately separate from the queue-based one-off path
/// (`LocalIngestService.importURL` → `pending` → `QueueRunner`) used
/// everywhere else in the app, because every other one-off *does* still
/// need transcription. The YouTube Explorer's "In Library übernehmen"
/// button is the one place where the transcript already exists in full
/// before the episode row is even created.
public enum YouTubeExplorerLibrarySave {

    public static func save(
        _ transcript: ExtractedTranscript,
        store: StateStore,
        watchlistURL: URL,
        outputRoot: URL,
        settings: Settings
    ) async throws -> IngestResult {
        let webpageURL = "https://www.youtube.com/watch?v=\(transcript.videoID)"
        let showSlug = transcript.channelID.map { "youtube-\($0)" } ?? "youtube-explorer"
        // The channel's DISPLAY name (e.g. "The Diary Of A CEO") — not the
        // @handle — both titles the saved show AND is threaded through as
        // `author` below, so a same-creator podcast (author/title normalises
        // to the same key) is grouped with it by `CreatorAggregator`. Falls
        // back to the handle/ID when yt-dlp couldn't resolve the display
        // name, same as before this change.
        let showTitle = transcript.channelName ?? transcript.channelHandle ?? transcript.channelID ?? "YouTube"

        let ingest = LocalIngestService(store: store, watchlistURL: watchlistURL)
        let result = try ingest.importURL(
            title: transcript.title,
            webpageURL: webpageURL,
            showSlug: showSlug,
            showTitle: showTitle,
            author: transcript.channelName,
            source: "youtube"
        )

        let fullText = transcript.segments.map(\.text).joined(separator: " ")
        let origin = TranscriptOrigin(
            method: transcript.source == .engine ? .asr : .captions,
            captionKind: transcript.source == .captions
                ? (transcript.captionsAuto == true ? .auto : .manual)
                : nil
        )
        let transcriptionResult = TranscriptionResult(
            text: fullText,
            segments: transcript.segments,
            language: transcript.language,
            origin: origin
        )

        guard var episode = try store.episode(guid: result.guid) else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Populate transcriptOrigin on the in-memory episode BEFORE handing it
        // to the writer, so the .md frontmatter (MarkdownLibraryWriter reads
        // episode.transcriptOrigin via obsidianEnrichment) carries the correct
        // provenance on the very first save — the DB row itself only gets this
        // value below, via setStatus, which runs after the write.
        episode.transcriptOrigin = origin.storageString

        let writer = MarkdownLibraryWriter(
            outputRoot: outputRoot,
            writeSRT: settings.saveSrt,
            writeTXT: settings.saveTxt,
            writeHTML: settings.saveHtml,
            writeOKF: settings.saveOkf,
            writeVTT: settings.saveVtt,
            writeCSV: settings.saveCsv
        )
        let transcriptURL = try await writer.write(
            episode: episode,
            transcript: transcriptionResult,
            ocrText: nil,
            mediaPath: nil
        )

        try store.setStatus(
            guid: result.guid,
            .done,
            transcriptPath: transcriptURL.path,
            transcriptOrigin: origin.storageString
        )

        Log.info("YouTube Explorer: saved to library",
                 component: "YouTubeExplorerLibrarySave",
                 context: [("guid", result.guid), ("videoID", transcript.videoID)])

        // Auto-merge when unambiguous. Runs HERE (not only in the Explorer's
        // save button) so the Chrome-extension BACKGROUND intake
        // (`YouTubeIntakeCoordinator` → this same save) also links a just-saved
        // YouTube channel to an existing podcast of the same creator — the
        // user's "auch beim Hintergrund-Intake auto-linken" ask. Best-effort:
        // the transcript is already persisted above, so a failure here only
        // leaves the two ungrouped (still fixable via the Explorer's manual
        // link menu or Library drag-and-drop merge).
        autoLinkCreatorIfUnambiguous(
            channelName: transcript.channelName,
            ytSlug: showSlug,
            videoID: transcript.videoID,
            watchlistURL: watchlistURL
        )

        return result
    }

    /// Sets the just-saved YouTube show's explicit `creator` to a matched
    /// library show's name when — and only when — exactly one existing
    /// non-YouTube show is the same creator
    /// (``CreatorAggregator/matchingShows(forChannelName:in:)``), so
    /// ``CreatorAggregator``'s priority-1 explicit-creator key equals the
    /// podcast's key and they group. `author == channelName` alone is NOT
    /// enough when the names differ (e.g. channel "The Diary Of A CEO" vs.
    /// podcast "The Diary Of A CEO with Steven Bartlett").
    ///
    /// Reads the watchlist fresh from disk: at this point `importURL` has
    /// already added the new YouTube show, but `matchingShows` excludes
    /// `source == "youtube"`, so the new show can never match itself.
    static func autoLinkCreatorIfUnambiguous(
        channelName: String?,
        ytSlug: String,
        videoID: String,
        watchlistURL: URL
    ) {
        guard let name = channelName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        do {
            let watchlistStore = try WatchlistStore.load(from: watchlistURL)
            let matches = CreatorAggregator.matchingShows(forChannelName: name, in: watchlistStore.watchlist.shows)
            guard matches.count == 1, let matched = matches.first else { return }
            let matchedCreator = matched.creator?.trimmingCharacters(in: .whitespaces)
            let creatorName = (matchedCreator?.isEmpty == false) ? matchedCreator! : matched.displayName
            try watchlistStore.updateCreator(slug: ytSlug, creator: creatorName, to: watchlistURL)
            Log.info("YouTube Explorer: auto-linked YouTube channel to \(creatorName)",
                     component: "YouTubeExplorerLibrarySave",
                     context: [("videoID", videoID), ("matchedShow", matched.slug), ("creator", creatorName)])
        } catch {
            Log.warn("YouTube Explorer: auto-link failed (transcript still saved)",
                     component: "YouTubeExplorerLibrarySave", context: [("error", "\(error)")])
        }
    }
}
