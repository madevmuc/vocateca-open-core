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
        let showTitle = transcript.channelHandle ?? transcript.channelID ?? "YouTube"

        let ingest = LocalIngestService(store: store, watchlistURL: watchlistURL)
        let result = try ingest.importURL(
            title: transcript.title,
            webpageURL: webpageURL,
            showSlug: showSlug,
            showTitle: showTitle,
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

        return result
    }
}
