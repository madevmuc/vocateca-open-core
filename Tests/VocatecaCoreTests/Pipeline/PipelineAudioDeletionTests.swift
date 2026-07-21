import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - PipelineAudioDeletionTests

/// Audio-reclaim tests for the `deleteMp3AfterTranscribe` default flip
/// (2026-07-21): a `true` fresh-install default previously deleted media
/// immediately, but `Pipeline` never actually did the deleting — only
/// `MaintenanceRunner`'s periodic sweep did, so a downloaded `.mp3` survived
/// until the next maintenance tick. That gap (plus the earlier `false` default)
/// let a 37.6 GB MP3 buildup accumulate, manually deleted. This proves the new
/// immediate reclaim in `Pipeline`'s audio-transcribe done block: the file is
/// gone (and `mp3_path` cleared) the instant `.done` is durably persisted, and
/// ONLY then — a failed transcription or a `false` setting must always keep
/// the audio.
///
/// Harness mirrors `DiarizationIntegrationTests`' settings-swap pattern:
/// `Pipeline.process` reads `deleteMp3AfterTranscribe` via a fixed path
/// (`SettingsStore.load(from: Paths.settingsURL)`), so each test installs a
/// real `settings.yaml`, restoring the prior file in `tearDown`.
final class PipelineAudioDeletionTests: XCTestCase {

    // MARK: - File-swap helpers

    private var savedSettingsData: Data?
    private let settingsURL = Paths.settingsURL

    override func tearDown() {
        if let data = savedSettingsData {
            try? data.write(to: settingsURL)
        } else {
            try? FileManager.default.removeItem(at: settingsURL)
        }
        savedSettingsData = nil
        super.tearDown()
    }

    private func installSettings(deleteAfterTranscribe: Bool) throws {
        savedSettingsData = try? Data(contentsOf: settingsURL)
        var settings = Settings()
        settings.deleteMp3AfterTranscribe = deleteAfterTranscribe
        try SettingsStore.save(settings, to: settingsURL)
    }

    private func makePipeline(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber,
        writer: any LibraryWriter
    ) -> Pipeline {
        Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: writer
        )
    }

    // MARK: - deleteMp3AfterTranscribe == true → audio deleted + mp3_path cleared

    func testDeleteAfterTranscribeTrueDeletesAudioAndClearsMp3Path() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try installSettings(deleteAfterTranscribe: true)

        let ep = Episode.makePodcast(guid: "audio-del-001")
        try store.upsert(ep)

        // A REAL file on disk — the deletion path stats/removes it for real.
        let mediaURL = dir.appendingPathComponent("audio-del-001.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        let transcriptURL = dir.appendingPathComponent("audio-del-001.md")

        let downloader = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let writer = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(store: store, downloader: downloader, transcriber: transcriber, writer: writer)
        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path),
                        "audio must be deleted after a successful transcription")
        let saved = try XCTUnwrap(store.episode(guid: "audio-del-001"))
        XCTAssertNil(saved.mp3Path, "mp3_path must be cleared once the file is reclaimed")
    }

    // MARK: - deleteMp3AfterTranscribe == false → audio kept

    func testDeleteAfterTranscribeFalseKeepsAudio() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try installSettings(deleteAfterTranscribe: false)

        let ep = Episode.makePodcast(guid: "audio-keep-001")
        try store.upsert(ep)

        let mediaURL = dir.appendingPathComponent("audio-keep-001.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        let transcriptURL = dir.appendingPathComponent("audio-keep-001.md")

        let downloader = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let writer = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(store: store, downloader: downloader, transcriber: transcriber, writer: writer)
        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path),
                       "audio must be kept when deleteMp3AfterTranscribe is off")
        let saved = try XCTUnwrap(store.episode(guid: "audio-keep-001"))
        XCTAssertNotNil(saved.mp3Path, "mp3_path must remain set when the file is kept")
    }

    // MARK: - Failed transcription → audio kept even with the setting on

    func testFailedTranscriptionKeepsAudioEvenWithDeleteAfterTranscribeTrue() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try installSettings(deleteAfterTranscribe: true)

        let ep = Episode.makePodcast(guid: "audio-fail-001")
        try store.upsert(ep)

        let mediaURL = dir.appendingPathComponent("audio-fail-001.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        let transcriptURL = dir.appendingPathComponent("audio-fail-001.md")

        let downloader = FakeDownloader(.succeed(mediaURL))
        // A permanent transcription failure never reaches the `.done` block —
        // the reclaim code is unreachable, so the file must survive untouched.
        let transcriber = FakeTranscriber(.failPermanent("boom"))
        let writer = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(store: store, downloader: downloader, transcriber: transcriber, writer: writer)
        let result = await pipeline.process(ep)

        XCTAssertNotEqual(result.finalStatus, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path),
                       "a failed transcription must never delete the source audio")
    }
}
