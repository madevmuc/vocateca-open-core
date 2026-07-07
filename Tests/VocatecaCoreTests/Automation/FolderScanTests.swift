import XCTest
@testable import VocatecaCore

/// Tests for ``FolderScan`` — the pure, FSEvents-free folder scan helpers.
final class FolderScanTests: XCTestCase {

    // MARK: - isIngestable: media extensions

    /// Every extension in _MEDIA_EXTS (ported from Python) must be accepted.
    func testIsIngestableAcceptsAllMediaExtensions() {
        let mediaFiles = [
            "episode.mp3",
            "recording.m4a",
            "audiobook.m4b",
            "wav_file.wav",
            "aiff_file.aiff",
            "aif_file.aif",
            "lossless.flac",
            "vorbis.ogg",
            "vorbis_alt.oga",
            "opus_file.opus",
            "video.mp4",
            "video2.m4v",
            "quicktime.mov",
            "matroska.mkv",
            "web_video.webm",
            "old_avi.avi",
            "windows.wmv",
        ]
        for filename in mediaFiles {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertTrue(
                FolderScan.isIngestable(url),
                "Expected \(filename) to be ingestable"
            )
        }
    }

    /// Non-media extensions must be rejected.
    func testIsIngestableRejectsNonMedia() {
        let nonMediaFiles = [
            "document.pdf",
            "spreadsheet.xlsx",
            "notes.txt",
            "image.jpg",
            "photo.png",
            "archive.zip",
            "binary.exe",
            "script.py",
            "stylesheet.css",
            "readme.md",
        ]
        for filename in nonMediaFiles {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertFalse(
                FolderScan.isIngestable(url),
                "Expected \(filename) to NOT be ingestable"
            )
        }
    }

    /// Extension check is case-insensitive (Python uses `.lower()`).
    func testIsIngestableCaseInsensitive() {
        let cases = [
            "/tmp/episode.MP3",
            "/tmp/recording.M4A",
            "/tmp/video.MOV",
            "/tmp/mixed.Mp3",
            "/tmp/also.Flac",
        ]
        for path in cases {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(
                FolderScan.isIngestable(url),
                "Expected case-insensitive match for \(path)"
            )
        }
    }

    /// A file with no extension must not be ingestable.
    func testIsIngestableRejectsNoExtension() {
        let url = URL(fileURLWithPath: "/tmp/no_extension")
        XCTAssertFalse(FolderScan.isIngestable(url))
    }

    /// Extension-only path (starts with dot) must not be ingestable if not a media ext.
    func testIsIngestableRejectsDotFiles() {
        let url = URL(fileURLWithPath: "/tmp/.hidden")
        XCTAssertFalse(FolderScan.isIngestable(url))
    }

    /// Custom mediaExtensions override is respected.
    func testIsIngestableCustomExtensions() {
        let customExts: Set<String> = [".abc", ".xyz"]
        XCTAssertTrue(FolderScan.isIngestable(URL(fileURLWithPath: "/tmp/file.abc"), mediaExtensions: customExts))
        XCTAssertFalse(FolderScan.isIngestable(URL(fileURLWithPath: "/tmp/file.mp3"), mediaExtensions: customExts))
    }

    // MARK: - mediaExtensions set

    /// The set must contain exactly the 17 extensions from Python _MEDIA_EXTS.
    func testMediaExtensionsSetSize() {
        let expected: Set<String> = [
            ".mp3", ".m4a", ".m4b", ".wav", ".aiff", ".aif", ".flac",
            ".ogg", ".oga", ".opus", ".mp4", ".m4v", ".mov", ".mkv",
            ".webm", ".avi", ".wmv",
        ]
        XCTAssertEqual(FolderScan.mediaExtensions, expected,
            "Swift mediaExtensions must be byte-for-byte identical to Python _MEDIA_EXTS")
    }

    // MARK: - newMediaFiles

    /// Files already in knownPaths are excluded.
    func testNewMediaFilesDeduplication() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests_dedup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let known = tempDir.appendingPathComponent("known.mp3")
        let newFile = tempDir.appendingPathComponent("new.mp3")
        try Data().write(to: known)
        try Data().write(to: newFile)

        // Use the resolved path (resolves /tmp → /private/tmp on macOS).
        let knownResolved = known.resolvingSymlinksInPath().path
        let results = FolderScan.newMediaFiles(in: tempDir, knownPaths: [knownResolved])
        XCTAssertEqual(results.count, 1, "Should return only the unknown file")
        XCTAssertEqual(results.first?.lastPathComponent, "new.mp3")
    }

    /// Non-media files are excluded from scan results.
    func testNewMediaFilesFiltersNonMedia() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests_nonmedia_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data().write(to: tempDir.appendingPathComponent("audio.mp3"))
        try Data().write(to: tempDir.appendingPathComponent("document.pdf"))
        try Data().write(to: tempDir.appendingPathComponent("image.png"))

        let results = FolderScan.newMediaFiles(in: tempDir, knownPaths: [])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pathExtension.lowercased(), "mp3")
    }

    /// Recursive scan finds media files in subdirectories.
    func testNewMediaFilesRecursive() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests_recursive_\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("ShowA")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data().write(to: subDir.appendingPathComponent("ep1.mp3"))
        try Data().write(to: subDir.appendingPathComponent("ep2.flac"))

        let results = FolderScan.newMediaFiles(in: tempDir, knownPaths: [])
        XCTAssertEqual(results.count, 2, "Should find files in subdirectories")
    }

    /// Empty directory returns empty array.
    func testNewMediaFilesEmptyDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests_empty_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let results = FolderScan.newMediaFiles(in: tempDir, knownPaths: [])
        XCTAssertTrue(results.isEmpty)
    }

    /// Non-existent directory returns empty array gracefully.
    func testNewMediaFilesNonExistentDirectory() {
        let missing = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString)")
        let results = FolderScan.newMediaFiles(in: missing, knownPaths: [])
        XCTAssertTrue(results.isEmpty, "Should return empty for non-existent directory")
    }

    // MARK: - isStable (L5 — folder-watch size-stability check)

    /// Pure comparator coverage for ``FolderScan/isStable(current:previous:)``,
    /// independent of any real waiting. `AutomationRunner` (VocatecaPro)
    /// samples a watched file twice, a short interval apart, and only
    /// ingests it once two consecutive samples agree — this is the decision
    /// function behind that guard.
    func testIsStableComparator() throws {
        let date1 = Date(timeIntervalSince1970: 1_000)
        let date2 = Date(timeIntervalSince1970: 2_000)

        let a = FolderScan.FileStabilitySnapshot(size: 100, modificationDate: date1)
        let bSameSizeSameTime = FolderScan.FileStabilitySnapshot(size: 100, modificationDate: date1)
        let cGrownSize = FolderScan.FileStabilitySnapshot(size: 200, modificationDate: date1)
        let dNewerMtime = FolderScan.FileStabilitySnapshot(size: 100, modificationDate: date2)

        XCTAssertTrue(FolderScan.isStable(current: bSameSizeSameTime, previous: a),
            "Identical size AND mtime across two samples must be reported stable")
        XCTAssertFalse(FolderScan.isStable(current: cGrownSize, previous: a),
            "A size change between samples must be reported UNSTABLE")
        XCTAssertFalse(FolderScan.isStable(current: dNewerMtime, previous: a),
            "An mtime change between samples must be reported UNSTABLE even with the same size")
        XCTAssertFalse(FolderScan.isStable(current: nil, previous: a),
            "A missing current snapshot (file vanished / unreadable) must never be reported stable")
        XCTAssertFalse(FolderScan.isStable(current: a, previous: nil),
            "A missing previous snapshot must never be reported stable")
    }

    /// ``FolderScan/FileStabilitySnapshot/current(of:)`` reads the real size
    /// of a file on disk, and returns `nil` for a path that doesn't exist.
    func testFileStabilitySnapshotCurrentReadsRealSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests_stability_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.mp3")
        try Data(repeating: 0x00, count: 42).write(to: fileURL)

        let snapshot = FolderScan.FileStabilitySnapshot.current(of: fileURL)
        XCTAssertEqual(snapshot?.size, 42, "Snapshot size must match the real file size on disk")
        XCTAssertNotNil(snapshot?.modificationDate, "A real file must have a modification date")

        let missing = tempDir.appendingPathComponent("does-not-exist.mp3")
        XCTAssertNil(FolderScan.FileStabilitySnapshot.current(of: missing),
            "A non-existent file must produce a nil snapshot")
    }
}
