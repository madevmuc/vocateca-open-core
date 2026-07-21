import XCTest
import Foundation
import GRDB
@testable import VocatecaCore

/// Stability wave 1 — package 2 (C2): media retention was a dead path because
/// `mp3_path` was never written. These tests cover the two halves of the fix:
///  1. the one-time backfill sweep records paths for pre-existing downloaded files
///  2. the pipeline now persists `mp3_path` at the `.downloaded` transition, so a
///     pipeline-written (not test-seeded) path becomes a retention candidate.
final class Mp3PathBackfillTests: XCTestCase {

    private var dir: URL!
    private var mediaDir: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mp3Backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func insertEpisode(guid: String, showSlug: String, status: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO episodes (show_slug, guid, title, pub_date, mp3_url, status, mp3_path)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
            """, arguments: [showSlug, guid, "t", "2026-01-01", "http://x/\(guid).mp3", status])
        }
    }

    /// Writes a file at the exact path the downloader would have produced:
    /// `<mediaDir>/<slugify(showSlug)>/<makeSlug(guid)>.mp3`.
    @discardableResult
    private func placeDownloadedFile(guid: String, showSlug: String) throws -> String {
        let showDir = mediaDir.appendingPathComponent(TextNormalization.slugify(showSlug), isDirectory: true)
        try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
        let fileURL = showDir.appendingPathComponent("\(URLSessionDownloader.makeSlug(guid: guid)).mp3")
        try Data("audio".utf8).write(to: fileURL)
        return fileURL.path
    }

    func testBackfillRecordsPathForExistingFileOnce() throws {
        // A done episode with a file on disk but no recorded mp3_path.
        try insertEpisode(guid: "has-file", showSlug: "My Show", status: "done")
        let expectedPath = try placeDownloadedFile(guid: "has-file", showSlug: "My Show")

        // A done episode whose file is missing → must stay NULL (unmatched).
        try insertEpisode(guid: "no-file", showSlug: "My Show", status: "done")

        // A pending episode is never a backfill candidate (never downloaded).
        try insertEpisode(guid: "pending", showSlug: "My Show", status: "pending")
        try placeDownloadedFile(guid: "pending", showSlug: "My Show")  // even if a stray file exists

        var settings = Settings()
        settings.diskGuardEnabled = false
        // This test is about the one-time backfill sweep (step 0), not the
        // age-based reclaim pass (step 1) that runs in the same `run()` call —
        // with `deleteMp3AfterTranscribe` defaulting to `true` (2026-07-21) that
        // pass would immediately reclaim the file the backfill just recorded,
        // before the assertions below can see it. Isolate explicitly.
        settings.deleteMp3AfterTranscribe = false
        let runner = MaintenanceRunner(
            store: store, settings: settings, guardPath: dir.path, mediaDirOverride: mediaDir)
        _ = runner.run(nowISO: Event.nowISO())

        // Matched file → path recorded.
        XCTAssertEqual(try store.episode(guid: "has-file")?.mp3Path, expectedPath)
        // Missing file → still NULL.
        XCTAssertNil(try store.episode(guid: "no-file")?.mp3Path)
        // Pending → not in the candidate set, stays NULL.
        XCTAssertNil(try store.episode(guid: "pending")?.mp3Path)

        // Guard flag is stamped so a second pass is a no-op even if we now create
        // the previously-missing file.
        XCTAssertEqual(try store.metaValue(MaintenanceRunner.mp3BackfillDoneMetaKey), "1")
        _ = try placeDownloadedFile(guid: "no-file", showSlug: "My Show")
        _ = runner.run(nowISO: Event.nowISO())
        XCTAssertNil(try store.episode(guid: "no-file")?.mp3Path,
                     "the one-time sweep must not run again after the guard flag is set")
    }

    /// End-to-end: drive the real Pipeline to `done` and assert it persisted
    /// `mp3_path` (previously never written), making the row retention-eligible.
    ///
    /// Isolated from `deleteMp3AfterTranscribe` (default flipped to `true`
    /// 2026-07-21): this test's purpose is the `.downloaded`-transition write +
    /// retention-candidate visibility, not the post-`.done` audio reclaim
    /// (covered by `PipelineAudioDeletionTests`) — so the file must survive to
    /// be asserted on. Pins the setting off via a real `settings.yaml`,
    /// restoring whatever was there before.
    func testPipelineWritesMp3PathMakingRowRetentionEligible() async throws {
        let settingsURL = Paths.settingsURL
        let savedSettingsData = try? Data(contentsOf: settingsURL)
        defer {
            if let savedSettingsData {
                try? savedSettingsData.write(to: settingsURL)
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
        }
        var settings = Settings()
        settings.deleteMp3AfterTranscribe = false
        try SettingsStore.save(settings, to: settingsURL)

        let ep = Episode.makePodcast(guid: "pipe-mp3", showSlug: "test-show")
        try store.upsert(ep)

        let mediaURL = dir.appendingPathComponent("pipe-mp3.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        let transcriptURL = dir.appendingPathComponent("pipe-mp3.md")

        let pipeline = Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(mediaURL)),
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(outputURL: transcriptURL))

        let result = await pipeline.process(ep)
        XCTAssertEqual(result.finalStatus, .done)

        // The pipeline (not the test) wrote mp3_path.
        let saved = try XCTUnwrap(store.episode(guid: "pipe-mp3"))
        XCTAssertEqual(saved.mp3Path, mediaURL.path,
                       "pipeline must persist the download path at the .downloaded transition")

        // And it is now visible to the storage-cap enumeration (retention universe).
        let withFiles = try store.mp3sWithLocalFile().map(\.guid)
        XCTAssertTrue(withFiles.contains("pipe-mp3"),
                      "a pipeline-written path must appear in the retention candidate universe")
    }
}
