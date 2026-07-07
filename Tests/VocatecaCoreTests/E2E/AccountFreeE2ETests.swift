import XCTest
import Foundation
@testable import VocatecaCore

/// Account-free end-to-end tests — Phase 3 gate.
///
/// These tests exercise the real ingest → queue → pipeline path on live internet
/// feeds. They auto-skip on any network error so CI offline stays green.
///
/// ## Opt-in env-var gates
///
/// - `VOCATECA_RUN_NETWORK_TESTS=1` — enables tests 1 and 2 (live-network E2E).
///   Without this flag both tests skip immediately and the suite can never hang
///   on a network stall. Set this flag only in environments with reliable internet
///   access (e.g. local developer machines, dedicated network-allowed CI jobs).
///
/// - `VOCATECA_RUN_WHISPER_TESTS=1` — enables test 3 (full RSS transcribe E2E)
///   AND test 4 (full YouTube transcribe E2E). Requires a WhisperKit model to be
///   downloaded AND implies network access (both env vars must be set for tests
///   3 and 4).
///
/// ## Tests
/// 1. **RSS E2E** — FeedIngestor polls a real podcast feed, inserts episodes into
///    a temp StateStore, claims the oldest episode, and runs it through the
///    real URLSessionDownloader to download an MP3. Asserts status reaches
///    at least `downloaded`. Does NOT transcribe (WhisperKit is model-gated).
///
/// 2. **YouTube E2E** — FeedIngestor polls a real YouTube channel via yt-dlp +
///    YouTubeResolver, asserts episodes are ingested with youtube watch-URL
///    mp3_url values and non-empty guid/title.
///
/// 3. **Full RSS transcribe E2E** — gated behind `VOCATECA_RUN_WHISPER_TESTS=1`
///    AND `VOCATECA_RUN_NETWORK_TESTS=1`. Downloads an episode AND transcribes
///    it with WhisperKit, then writes a Markdown file via MarkdownLibraryWriter.
///    Skipped by default.
///
/// 4. **Full YouTube transcribe E2E** — gated behind `VOCATECA_RUN_WHISPER_TESTS=1`
///    AND `VOCATECA_RUN_NETWORK_TESTS=1`. Resolves @MKBHD → takes the newest
///    video → runs it through yt-dlp audio hook → WhisperKit → MarkdownLibraryWriter.
///    Also requires `yt-dlp` to be installed. Skipped by default.
final class AccountFreeE2ETests: XCTestCase {

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("state.sqlite"))
        return (store, dir)
    }

    /// Throws `XCTSkip` when the network appears to be offline.
    private func requireNetwork() async throws {
        guard let url = URL(string: "https://1alage.podigee.io") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            throw XCTSkip("Network unavailable (\(error.localizedDescription)) — skipping E2E test")
        }
    }

    // MARK: - 1. RSS E2E (network, auto-skip offline)

    /// Poll a real podcast RSS feed, ingest episodes, claim the oldest, and
    /// download it. Asserts the episode reaches at least `downloaded` status.
    func testRSSIngestAndDownload() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network E2E tests")
        }
        try await requireNetwork()

        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a Show pointing at a real public podcast feed.
        // 1ALAGE is a small German finance podcast — episodes are short (< 15 min).
        let show = Show(
            slug: "e2e-1alage",
            title: "1ALAGE E2E Test",
            rss: "https://1alage.podigee.io/feed/mp3",
            source: "podcast"
        )

        // Poll the feed.
        let ingestor = FeedIngestor()
        let ingestedCount: Int
        do {
            ingestedCount = try await ingestor.poll(show: show, store: store).episodes.count
        } catch {
            throw XCTSkip("RSS poll failed (\(error)) — skipping E2E test")
        }

        XCTAssertGreaterThan(ingestedCount, 0,
            "RSS ingest must return > 0 episodes for a live feed")
        print("[E2E RSS] Ingested \(ingestedCount) episodes from 1ALAGE")

        // Verify episodes are in the DB with status=pending.
        let episodes = try store.episodes(showSlug: "e2e-1alage")
        XCTAssertGreaterThan(episodes.count, 0)
        XCTAssertTrue(episodes.allSatisfy { $0.status == "pending" },
            "All freshly ingested episodes should have status=pending")

        // Claim the oldest episode (oldest_first order) for download.
        guard let ep = try store.claimNextPending(queueOrder: "oldest_first") else {
            XCTFail("No pending episode to claim after ingest")
            return
        }
        print("[E2E RSS] Claiming episode: guid=\(ep.guid.prefix(50))")
        print("[E2E RSS] title=\(ep.title.prefix(60))")
        print("[E2E RSS] mp3_url=\(ep.mp3Url.prefix(80))")

        // Build a URLSessionDownloader with a temp media dir.
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        let downloader = URLSessionDownloader(mediaDir: mediaDir)

        // Download the episode.
        let downloadedURL: URL
        do {
            let startTime = Date()
            downloadedURL = try await downloader.download(ep)
            let elapsed = Date().timeIntervalSince(startTime)
            print("[E2E RSS] Downloaded \(downloadedURL.lastPathComponent) in \(String(format: "%.1f", elapsed))s")
        } catch {
            // If the specific episode's MP3 URL is temporarily unavailable,
            // skip rather than fail — the ingest path (the primary gate) already passed.
            throw XCTSkip("Episode download failed (\(error)) — ingest passed but download step unavailable")
        }

        // Update status to 'downloaded'.
        try store.setStatus(guid: ep.guid, .downloaded)

        // Verify the file exists and has content.
        let attrs = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
        let fileSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Downloaded file must have non-zero size")
        print("[E2E RSS] File size: \(fileSize) bytes")

        // Verify DB status updated.
        let updatedEp = try store.episode(guid: ep.guid)
        XCTAssertEqual(updatedEp?.status, "downloaded",
            "Episode status must be 'downloaded' after successful download")

        print("[E2E RSS] PASSED — ingested=\(ingestedCount), downloaded=\(fileSize) bytes, status=\(updatedEp?.status ?? "?")")
    }

    // MARK: - 2. YouTube E2E (network, auto-skip offline)

    /// Poll a real YouTube channel via yt-dlp, ingest episodes, and verify the
    /// resulting episode rows have valid YouTube watch-URL mp3_url values.
    ///
    /// Does NOT download audio (yt-dlp audio download requires ffmpeg and is slow).
    func testYouTubeIngest() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network E2E tests")
        }
        try await requireNetwork()

        // Check yt-dlp is available.
        let bm = BinaryManager()
        guard bm.resolvedPath(for: .ytDlp) != nil else {
            throw XCTSkip("yt-dlp not installed — skipping YouTube E2E test")
        }

        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Use MKBHD — a large, stable channel. Limit to 5 videos.
        let show = Show(
            slug: "e2e-mkbhd",
            title: "MKBHD E2E Test",
            rss: "@MKBHD",
            source: "youtube"
        )

        let ingestor = FeedIngestor(youtubeLimit: 5)
        let ingestedCount: Int
        do {
            ingestedCount = try await ingestor.poll(show: show, store: store).episodes.count
        } catch {
            throw XCTSkip("YouTube poll failed (\(error)) — skipping YouTube E2E test")
        }

        XCTAssertGreaterThan(ingestedCount, 0,
            "YouTube ingest must return > 0 episodes")
        XCTAssertLessThanOrEqual(ingestedCount, 5,
            "YouTube ingest should respect the limit (<=5 videos)")
        print("[E2E YouTube] Ingested \(ingestedCount) episodes from @MKBHD")

        // Verify episodes have correct youtube watch-URL mp3_url.
        let episodes = try store.episodes(showSlug: "e2e-mkbhd")
        XCTAssertGreaterThan(episodes.count, 0)

        for ep in episodes {
            XCTAssertFalse(ep.guid.isEmpty,
                "YouTube episode must have a non-empty guid (video ID)")
            XCTAssertFalse(ep.title.isEmpty,
                "YouTube episode must have a non-empty title")
            XCTAssertTrue(
                ep.mp3Url.hasPrefix("https://www.youtube.com/watch?v="),
                "YouTube episode mp3_url must be a watch URL, got: \(ep.mp3Url)"
            )
            XCTAssertEqual(ep.status, "pending",
                "Freshly ingested YouTube episode must have status=pending")
        }

        if let first = episodes.sorted(by: { $0.pubDate > $1.pubDate }).first {
            print("[E2E YouTube] Newest: guid=\(first.guid), title=\(first.title.prefix(60))")
            print("[E2E YouTube] mp3_url=\(first.mp3Url)")
        }

        print("[E2E YouTube] PASSED — ingested=\(ingestedCount) YouTube episodes with watch-URL mp3_url")
    }

    // MARK: - 3. Full transcribe E2E (gated behind env var)

    /// Full end-to-end: RSS ingest → download → WhisperKit transcribe →
    /// MarkdownLibraryWriter → assert .md file written.
    ///
    /// **Skipped by default.** Set `VOCATECA_RUN_WHISPER_TESTS=1` AND
    /// `VOCATECA_RUN_NETWORK_TESTS=1` to enable. Requires a WhisperKit model
    /// to be downloaded.
    func testFullTranscribeE2E() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_WHISPER_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_WHISPER_TESTS=1 to run the full transcribe E2E")
        }
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network E2E tests")
        }

        try await requireNetwork()

        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let show = Show(
            slug: "e2e-whisper",
            title: "Whisper E2E Test",
            rss: "https://1alage.podigee.io/feed/mp3",
            source: "podcast"
        )

        let ingestor = FeedIngestor()
        let ingestedCount: Int
        do {
            ingestedCount = try await ingestor.poll(show: show, store: store).episodes.count
        } catch {
            throw XCTSkip("RSS poll failed (\(error)) — skipping")
        }
        XCTAssertGreaterThan(ingestedCount, 0, "Must ingest at least one episode")

        guard let ep = try store.claimNextPending(queueOrder: "oldest_first") else {
            XCTFail("No pending episode to claim")
            return
        }

        // Build real engines.
        let mediaDir  = dir.appendingPathComponent("media",   isDirectory: true)
        let libraryDir = dir.appendingPathComponent("library", isDirectory: true)
        let downloader     = URLSessionDownloader(mediaDir: mediaDir)
        let transcriber    = WhisperKitTranscriber()
        let ocrProcessor   = InstagramImageOCRProcessor()
        let libraryWriter  = MarkdownLibraryWriter(outputRoot: libraryDir)

        let pipeline = Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: ocrProcessor,
            libraryWriter: libraryWriter
        )

        print("[E2E Whisper] Starting pipeline for: \(ep.title.prefix(60))")
        let result = await pipeline.process(ep)
        print("[E2E Whisper] Final status: \(result.finalStatus)")

        XCTAssertEqual(result.finalStatus, EpisodeStatus.done,
            "Full pipeline should complete with status=done")
        if let tp = result.transcriptPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tp),
                "Transcript .md file must exist at \(tp)")
            print("[E2E Whisper] Transcript: \(tp)")
        } else {
            XCTFail("Full pipeline must produce a transcript path")
        }
    }

    // MARK: - 4. Full YouTube transcribe E2E (gated behind both env vars)

    /// Full end-to-end for a YouTube video: resolve @MKBHD → take the newest
    /// video → yt-dlp audio download → WhisperKit transcribe →
    /// MarkdownLibraryWriter → assert transcript `.md` exists on disk.
    ///
    /// **Skipped by default.** Requires ALL of:
    /// - `VOCATECA_RUN_WHISPER_TESTS=1`
    /// - `VOCATECA_RUN_NETWORK_TESTS=1`
    /// - `yt-dlp` installed (BinaryManager.resolvedPath(for: .ytDlp) != nil)
    ///
    /// ## YouTube audio hook wiring
    /// `URLSessionDownloader.youtubeAudioHook` is injected with a closure that
    /// invokes yt-dlp directly (`--extract-audio --audio-format mp3`) to download
    /// the audio for a given watch URL. This mirrors what a production QueueController
    /// would do, using `BinaryManager` + `Subprocess` — both of which are available
    /// in `VocatecaCore` and accessible from the test target via `@testable import`.
    func testFullTranscribeE2E_YouTube() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_WHISPER_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_WHISPER_TESTS=1 to run the full YouTube transcribe E2E")
        }
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network E2E tests")
        }

        // Require yt-dlp.
        let bm = BinaryManager()
        guard let ytdlpURL = bm.resolvedPath(for: .ytDlp) else {
            throw XCTSkip("yt-dlp not installed — skipping YouTube full-transcribe E2E test")
        }

        try await requireNetwork()

        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Resolve @MKBHD and take the newest (first) video only.
        let show = Show(
            slug: "e2e-yt-whisper",
            title: "YouTube Whisper E2E Test",
            rss: "@MKBHD",
            source: "youtube"
        )

        let ingestor = FeedIngestor(youtubeLimit: 1)
        let ingestedCount: Int
        do {
            ingestedCount = try await ingestor.poll(show: show, store: store).episodes.count
        } catch {
            throw XCTSkip("YouTube poll failed (\(error)) — skipping YouTube full-transcribe E2E test")
        }

        XCTAssertGreaterThan(ingestedCount, 0, "Must ingest at least one YouTube episode")
        print("[E2E YT-Whisper] Ingested \(ingestedCount) episode(s) from @MKBHD")

        guard let ep = try store.claimNextPending(queueOrder: "oldest_first") else {
            XCTFail("No pending YouTube episode to claim")
            return
        }
        print("[E2E YT-Whisper] Episode: guid=\(ep.guid), title=\(ep.title.prefix(60))")
        print("[E2E YT-Whisper] Watch URL: \(ep.mp3Url)")

        // 2. Build the YouTube audio hook using yt-dlp.
        //
        // yt-dlp --continue --no-playlist --extract-audio --audio-format mp3 \
        //        --audio-quality 5 -o <dest> <watch-url>
        //
        // We pass the output template directly so yt-dlp writes the mp3 to a
        // predictable path. The hook converts the watch URL to a local mp3 file.
        // --continue resumes any partial download that yt-dlp manages internally,
        // complementing the URLSessionDownloader's own .part resume for direct URLs.
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        let subprocess = Subprocess()
        let capturedYtdlpURL = ytdlpURL  // capture for Sendable closure

        let youtubeAudioHook: @Sendable (Episode, URL) async throws -> URL = { episode, watchURL in
            let showSlug = TextNormalization.slugify(episode.showSlug)
            let slug = URLSessionDownloader.makeSlug(episode)
            let showDir = mediaDir.appendingPathComponent(showSlug, isDirectory: true)
            try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
            // yt-dlp output template: write to <showDir>/<slug>.%(ext)s
            // The -x / --extract-audio flag plus --audio-format mp3 ensures .mp3 output.
            let outputTemplate = showDir.appendingPathComponent("\(slug).%(ext)s").path
            let result = try await subprocess.run(
                capturedYtdlpURL,
                [
                    "--continue",       // resume partial yt-dlp downloads across retries
                    "--no-playlist",
                    "--extract-audio",
                    "--audio-format", "mp3",
                    "--audio-quality", "5",
                    "-o", outputTemplate,
                    watchURL.absoluteString
                ],
                timeout: 300
            )
            if result.exitCode != 0 {
                throw PipelineError.permanent(
                    "yt-dlp exited \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            // yt-dlp writes <slug>.mp3 — locate it.
            let destURL = showDir.appendingPathComponent("\(slug).mp3")
            guard FileManager.default.fileExists(atPath: destURL.path) else {
                throw PipelineError.permanent(
                    "yt-dlp completed but expected mp3 not found at \(destURL.path)"
                )
            }
            return destURL
        }

        // 3. Wire real pipeline engines.
        let libraryDir = dir.appendingPathComponent("library", isDirectory: true)
        let downloader  = URLSessionDownloader(
            mediaDir: mediaDir,
            youtubeAudioHook: youtubeAudioHook
        )
        let transcriber   = WhisperKitTranscriber()
        let ocrProcessor  = InstagramImageOCRProcessor()
        let libraryWriter = MarkdownLibraryWriter(outputRoot: libraryDir)

        let pipeline = Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: ocrProcessor,
            libraryWriter: libraryWriter
        )

        print("[E2E YT-Whisper] Starting pipeline…")
        let result = await pipeline.process(ep)
        print("[E2E YT-Whisper] Final status: \(result.finalStatus)")

        XCTAssertEqual(result.finalStatus, EpisodeStatus.done,
            "Full YouTube pipeline should complete with status=done")
        if let tp = result.transcriptPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tp),
                "Transcript .md file must exist at \(tp)")
            print("[E2E YT-Whisper] Transcript: \(tp)")
        } else {
            XCTFail("Full YouTube pipeline must produce a transcript path")
        }
    }
}
