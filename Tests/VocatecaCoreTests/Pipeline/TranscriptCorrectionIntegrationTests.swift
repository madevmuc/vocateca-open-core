import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - TranscriptCorrectionIntegrationTests

/// End-to-end proof that the proper-noun corrector is wired into the
/// transcription pipeline: a fake transcriber emits the ASR mishearing
/// "Gokumo" while the episode/show metadata carries the correct brand
/// "gocomo", and the written `.md` must contain "gocomo" (not "Gokumo").
///
/// This is the acceptance test for Task 7 — the user's reported bug
/// (ASR writes "Gokumo"/"Fertina" when the title says "gocomo"/"Firtina").
///
/// Harness mirrors `PipelineAssumeSpeechTests`: `Pipeline.process` reads the
/// show via `Watchlist.load(from: Paths.watchlistURL)` and the correction
/// level via `SettingsStore.load(from: Paths.settingsURL)` — both fixed
/// paths — so each test installs a real single-show `watchlist.yaml` and a
/// real `settings.yaml`, restoring the prior files in `tearDown`.
///
/// The **real** `MarkdownLibraryWriter` is used (writing an actual `.md` into
/// a temp dir) so the assertion reads the true on-disk output, not an
/// in-memory capture.
final class TranscriptCorrectionIntegrationTests: XCTestCase {

    // MARK: - File-swap helpers

    private var savedWatchlistData: Data?
    private var savedSettingsData: Data?
    private let watchlistURL = Paths.watchlistURL
    private let settingsURL = Paths.settingsURL

    override func tearDown() {
        restore(savedWatchlistData, to: watchlistURL)
        restore(savedSettingsData, to: settingsURL)
        savedWatchlistData = nil
        savedSettingsData = nil
        super.tearDown()
    }

    private func restore(_ data: Data?, to url: URL) {
        if let data {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns the transcript **body** of a rendered `.md` (everything after the
    /// closing `---` of the YAML frontmatter). The episode title lives in the
    /// frontmatter and legitimately carries the correct proper-noun spellings, so
    /// the correction assertions must look only at the transcript body the ASR
    /// segments produced — never the frontmatter.
    private func transcriptBody(of markdown: String) -> String {
        // Frontmatter is `---\n...\n---\n<body>`. Drop through the 2nd delimiter.
        let parts = markdown.components(separatedBy: "\n---")
        // parts[0] == "---\n<yaml>", parts[1] == "\n<body>" (+ any later "---").
        guard parts.count >= 2 else { return markdown }
        return parts.dropFirst().joined(separator: "\n---")
    }

    private func installShow(_ show: Show) throws {
        savedWatchlistData = try? Data(contentsOf: watchlistURL)
        let store = WatchlistStore(watchlist: Watchlist(shows: [show]))
        try store.save(to: watchlistURL)
    }

    private func installCorrectionLevel(_ level: String) throws {
        savedSettingsData = try? Data(contentsOf: settingsURL)
        var settings = Settings()
        settings.properNounCorrection = level
        try SettingsStore.save(settings, to: settingsURL)
    }

    // MARK: - Fixture: ASR mishears the brand + a name

    /// The transcriber returns "Gokumo" (mishearing of "gocomo") and
    /// "Fertina" (mishearing of "Firtina") — both present in the show title.
    private static func misheardResult() -> TranscriptionResult {
        TranscriptionResult(
            text: "Heute bei Gokumo mit Sascha Fertina.",
            segments: [
                TranscriptionSegment(start: 0, end: 3,
                                     text: "Heute bei Gokumo mit Sascha Fertina.",
                                     noSpeechProb: 0.0, avgLogprob: -0.1)
            ],
            language: "de"
        )
    }

    private func makePipeline(store: StateStore, outputRoot: URL) -> Pipeline {
        Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/correction.mp3"))),
            transcriber: FakeTranscriber(.succeed(Self.misheardResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: MarkdownLibraryWriter(outputRoot: outputRoot, writeSRT: false)
        )
    }

    // The show title carries the correct spellings the corrector should snap to.
    // NB: the slug is deliberately brand-free ("show-x") — the show_slug is baked
    // into the markdown frontmatter, so a slug containing "gocomo" would make the
    // brand appear in the `.md` even without correction and defeat the assertion.
    private func brandShow(assumeSpeech: Bool = true) -> Show {
        Show(slug: "show-x",
             title: "Sascha Firtina, Co-Founder von gocomo",
             rss: "https://example.com/rss",
             assumeSpeech: assumeSpeech)
    }

    // MARK: - conservative (default) → corrected

    func testConservativeCorrectionRewritesMisheardBrandInWrittenMarkdown() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(brandShow())
        try installCorrectionLevel("conservative")

        // The episode title carries the correct spellings ("gocomo"/"Firtina")
        // the corrector snaps the ASR mishearings to — the real-world shape of
        // the user's bug (a guest/brand named in the episode title).
        let ep = Episode.makePodcast(
            guid: "corr-001", showSlug: "show-x",
            title: "Folge #12, Sascha Firtina, Co-Founder von gocomo",
            durationSec: 120)
        try store.upsert(ep)

        let result = await makePipeline(store: store, outputRoot: outputRoot).process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        let body = transcriptBody(of: md)

        XCTAssertTrue(body.contains("gocomo"),
                      "corrected brand must appear in the transcript body\n\(body)")
        XCTAssertFalse(body.contains("Gokumo"),
                       "the ASR mishearing must NOT survive to the transcript body\n\(body)")
        XCTAssertTrue(body.contains("Firtina"),
                      "corrected name must appear in the transcript body\n\(body)")
        XCTAssertFalse(body.contains("Fertina"),
                       "the ASR name mishearing must NOT survive\n\(body)")
    }

    // MARK: - off → mishearing survives

    func testOffLeavesMishearingUntouched() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputRoot = dir.appendingPathComponent("library", isDirectory: true)

        try installShow(brandShow())
        try installCorrectionLevel("off")

        // Same title as the corrected case — only the setting differs — so the
        // proof is the flag, not the metadata.
        let ep = Episode.makePodcast(
            guid: "corr-002", showSlug: "show-x",
            title: "Folge #12, Sascha Firtina, Co-Founder von gocomo",
            durationSec: 120)
        try store.upsert(ep)

        let result = await makePipeline(store: store, outputRoot: outputRoot).process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        let mdPath = try XCTUnwrap(result.transcriptPath)
        let md = try String(contentsOfFile: mdPath, encoding: .utf8)
        let body = transcriptBody(of: md)

        XCTAssertTrue(body.contains("Gokumo"),
                      "with correction off, the ASR mishearing must be preserved verbatim\n\(body)")
        XCTAssertFalse(body.contains("gocomo"),
                       "with correction off, the mishearing must NOT be corrected to the brand\n\(body)")
        XCTAssertTrue(body.contains("Fertina"),
                      "with correction off, the name mishearing must be preserved verbatim\n\(body)")
    }

    // MARK: - buildCorrection: glossary gated by level, manual prompt always kept

    /// Focused unit test on `Pipeline.buildCorrection` (the prompt-biasing seam
    /// threaded into `transcribe(...)`), independent of a full pipeline run.
    ///
    /// With `properNounCorrection == "off"` the auto-glossary must NOT bias the
    /// decoder — `TranscriptionContext.glossary` must be empty — but the show's
    /// MANUAL `whisperPrompt` is an independent, always-on feature and must
    /// still appear in `context.prompt`. With `"conservative"` the auto-glossary
    /// must be present in `context.glossary`.
    func testBuildCorrectionGatesGlossaryByLevelButAlwaysKeepsManualPrompt() {
        let show = Show(slug: "show-x",
                         title: "Sascha Firtina, Co-Founder von gocomo",
                         rss: "https://example.com/rss",
                         whisperPrompt: "MyManualPrompt")
        let episode = Episode.makePodcast(
            guid: "corr-003", showSlug: "show-x",
            title: "Folge #12, Sascha Firtina, Co-Founder von gocomo")

        let off = Pipeline.buildCorrection(episode: episode, show: show, language: "de",
                                           level: .off)
        XCTAssertEqual(off.context.glossary, [],
                       "'.off' must not bias the decoder with the auto-glossary")
        XCTAssertNotNil(off.context.prompt)
        XCTAssertTrue(off.context.prompt?.contains("MyManualPrompt") ?? false,
                      "the manual whisperPrompt must survive '.off' — it is independent of auto-correction\n\(off.context.prompt ?? "nil")")

        let conservative = Pipeline.buildCorrection(episode: episode, show: show, language: "de",
                                                     level: .conservative)
        XCTAssertFalse(conservative.context.glossary.isEmpty,
                       "'.conservative' must include the auto-glossary terms")
        XCTAssertTrue(conservative.context.prompt?.contains("MyManualPrompt") ?? false,
                      "the manual whisperPrompt must also survive '.conservative'\n\(conservative.context.prompt ?? "nil")")
    }
}
