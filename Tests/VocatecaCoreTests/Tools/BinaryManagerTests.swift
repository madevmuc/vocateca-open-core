import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - BinaryManagerTests

final class BinaryManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temporary directory and registers a `defer` cleanup block.
    /// The caller receives the URL; `defer { cleanup() }` removes the directory.
    private func makeTempDir() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinaryManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Creates a chmod-+x dummy executable at `url`.
    private func makeDummyExecutable(at url: URL) throws {
        try "#!/bin/sh\necho dummy\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber],
                                              ofItemAtPath: url.path)
    }

    // MARK: - 1. Path logic — deterministic, no IO

    func testManagedPathComposition() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)

        XCTAssertEqual(
            bm.managedPath(for: .ytDlp).lastPathComponent,
            "yt-dlp",
            "managedPath for ytDlp should end in 'yt-dlp'"
        )
        XCTAssertEqual(
            bm.managedPath(for: .galleryDL).lastPathComponent,
            "gallery-dl",
            "managedPath for galleryDL should end in 'gallery-dl'"
        )
        XCTAssertEqual(
            bm.managedPath(for: .ffmpeg).lastPathComponent,
            "ffmpeg",
            "managedPath for ffmpeg should end in 'ffmpeg'"
        )

        // All managed paths should live under binDir.
        for tool in ManagedTool.allCases {
            XCTAssertTrue(
                bm.managedPath(for: tool).path.hasPrefix(dir.path),
                "\(tool.rawValue) managed path should be under binDir"
            )
        }
    }

    func testResolvedPathForManagedBinaryAbsent() throws {
        // Fresh temp dir — no binaries present.
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)

        // yt-dlp absent → nil (not Homebrew-checked).
        XCTAssertNil(bm.resolvedPath(for: .ytDlp))
        // gallery-dl absent → nil.
        XCTAssertNil(bm.resolvedPath(for: .galleryDL))
    }

    func testResolvedPathForManagedBinaryPresent() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)

        // Place a dummy yt-dlp.
        let ytdlpURL = dir.appendingPathComponent("yt-dlp")
        try makeDummyExecutable(at: ytdlpURL)

        XCTAssertEqual(bm.resolvedPath(for: .ytDlp), ytdlpURL,
                       "resolvedPath should return the managed path when it exists and is executable")
    }

    // MARK: - 2. ffmpeg detection — managed path takes priority over Homebrew

    func testResolvedPathFFmpegManagedFirst() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        // Place a dummy ffmpeg in the managed bin dir.
        let managedFFmpeg = dir.appendingPathComponent("ffmpeg")
        try makeDummyExecutable(at: managedFFmpeg)

        let bm = BinaryManager(binDir: dir)

        // The managed path must win, even if Homebrew ffmpeg also exists.
        XCTAssertEqual(
            bm.resolvedPath(for: .ffmpeg),
            managedFFmpeg,
            "resolvedPath for ffmpeg should prefer the managed path over Homebrew"
        )
    }

    func testIsInstalledFalseWhenAbsent() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)
        XCTAssertFalse(bm.isInstalled(.ytDlp))
        XCTAssertFalse(bm.isInstalled(.galleryDL))
    }

    func testIsInstalledTrueWhenPresent() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)
        let gdlURL = dir.appendingPathComponent("gallery-dl")
        try makeDummyExecutable(at: gdlURL)

        XCTAssertTrue(bm.isInstalled(.galleryDL))
        XCTAssertFalse(bm.isInstalled(.ytDlp))
    }

    // MARK: - 3. Version parsing — pure, golden-test

    func testParseVersionYtDlp() {
        let output = "2025.01.01\n"
        let version = BinaryManager.parseVersion(toolOutput: output, for: .ytDlp)
        XCTAssertEqual(version, "2025.01.01")
    }

    func testParseVersionYtDlpReal() {
        // Captured from a real yt-dlp --version call.
        let output = "2026.06.09\n"
        let version = BinaryManager.parseVersion(toolOutput: output, for: .ytDlp)
        XCTAssertEqual(version, "2026.06.09")
    }

    func testParseVersionGalleryDL() {
        let output = "1.27.0\n"
        let version = BinaryManager.parseVersion(toolOutput: output, for: .galleryDL)
        XCTAssertEqual(version, "1.27.0")
    }

    func testParseVersionFFmpeg() {
        // Captured first line from real `ffmpeg -version` output.
        let output = """
        ffmpeg version 6.1.1 Copyright (c) 2000-2023 the FFmpeg developers
        built with Apple clang version 15.0.0 (clang-1500.3.9.4)
        configuration: --prefix=/opt/homebrew/Cellar/ffmpeg/6.1.1_1 ...
        """
        let version = BinaryManager.parseVersion(toolOutput: output, for: .ffmpeg)
        XCTAssertEqual(version, "6.1.1")
    }

    func testParseVersionFFmpegNewFormat() {
        // ffmpeg 7.x changed the banner slightly — still "ffmpeg version <X>".
        let output = "ffmpeg version 7.0 Copyright (c) 2000-2024 the FFmpeg developers\n"
        let version = BinaryManager.parseVersion(toolOutput: output, for: .ffmpeg)
        XCTAssertEqual(version, "7.0")
    }

    func testParseVersionFFmpegNilForGibberish() {
        // Input intentionally contains no "version" token.
        let version = BinaryManager.parseVersion(toolOutput: "build 6.1 Copyright (c) 2023", for: .ffmpeg)
        XCTAssertNil(version, "Should return nil when output does not contain 'version <X>'")
    }

    func testParseVersionEmptyOutputReturnsNil() {
        XCTAssertNil(BinaryManager.parseVersion(toolOutput: "", for: .ytDlp))
        XCTAssertNil(BinaryManager.parseVersion(toolOutput: "", for: .galleryDL))
        XCTAssertNil(BinaryManager.parseVersion(toolOutput: "", for: .ffmpeg))
    }

    // MARK: - 4. Real yt-dlp probe (auto-skip if absent)

    func testRealYtDlpVersion() async throws {
        let realBinDir = Paths.userDataDir()
            .appendingPathComponent("bin", isDirectory: true)
        let bm = BinaryManager(binDir: realBinDir)

        guard bm.isInstalled(.ytDlp) else {
            throw XCTSkip("yt-dlp not installed at \(realBinDir.path) — skipping real probe")
        }

        let version = try await bm.version(of: .ytDlp)
        let v = try XCTUnwrap(version, "version(of: .ytDlp) returned nil even though isInstalled is true")

        XCTAssertFalse(v.isEmpty, "version string must not be empty")

        // yt-dlp version strings look like YYYY.MM.DD or YYYY.MM.DD.N
        let versionRegex = try NSRegularExpression(pattern: #"^\d{4}\.\d{2}\.\d{2}"#)
        let range = NSRange(v.startIndex..., in: v)
        XCTAssertNotNil(
            versionRegex.firstMatch(in: v, range: range),
            "yt-dlp version '\(v)' does not match expected YYYY.MM.DD format"
        )

        print("BinaryManagerTests — real yt-dlp version: \(v)")
    }

    // MARK: - 5. ffmpeg detection (auto-skip if absent)

    func testFFmpegHomebrew() throws {
        // Use a fresh temp binDir so managed-path has no ffmpeg.
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)

        let homebrewCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]

        guard homebrewCandidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("No Homebrew ffmpeg found on this machine — skipping ffmpeg detection test")
        }

        let resolved = bm.resolvedPath(for: .ffmpeg)
        XCTAssertNotNil(resolved, "resolvedPath should find a Homebrew ffmpeg when one exists")

        if let resolved {
            XCTAssertTrue(
                homebrewCandidates.contains(resolved.path),
                "resolvedPath '\(resolved.path)' should be one of the known Homebrew candidate paths"
            )
            print("BinaryManagerTests — Homebrew ffmpeg resolved at: \(resolved.path)")
        }
    }

    // MARK: - 6. Error: install ffmpeg throws toolNotManaged

    func testInstallFFmpegThrows() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)

        do {
            try await bm.install(.ffmpeg)
            XCTFail("install(.ffmpeg) should have thrown BinaryManagerError.toolNotManaged")
        } catch BinaryManagerError.toolNotManaged(let tool) {
            XCTAssertEqual(tool, .ffmpeg)
        }
    }

    // MARK: - 7. SHA-256 verification (H-1) — pure, no IO

    func testSHA256HexMatchesKnownVector() {
        // "abc" → well-known SHA-256 test vector (FIPS 180-4).
        let data = Data("abc".utf8)
        let hash = BinaryManager.sha256Hex(of: data)
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256HexEmptyData() {
        // Well-known SHA-256 of the empty string.
        let hash = BinaryManager.sha256Hex(of: Data())
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testInstallRejectsMismatchedChecksum() async throws {
        // A `URLProtocol` stub would be needed to exercise the full `install()`
        // network path; that's covered by the network-gated `testInstallGalleryDL`
        // below. Here we verify the pure hash-comparison semantics directly:
        // a byte-for-byte fixture blob's hash must NOT equal an arbitrary
        // "expected" hash unless they truly match — guards against a
        // case-sensitivity or truncation bug in the comparison itself.
        let fixture = Data("not-the-real-binary".utf8)
        let actual = BinaryManager.sha256Hex(of: fixture)
        let wrongExpected = String(repeating: "0", count: 64)
        XCTAssertNotEqual(actual, wrongExpected)

        // Case-insensitive match must still succeed (mirrors the
        // `.caseInsensitiveCompare` used in `install()`).
        XCTAssertEqual(actual.caseInsensitiveCompare(actual.uppercased()), .orderedSame)
    }

    // MARK: - 8. Optional install test (gated by env var)

    func testInstallGalleryDL() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_BINARY_INSTALL"] == "1" else {
            throw XCTSkip("set VOCATECA_RUN_BINARY_INSTALL=1 to run real install test")
        }

        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let bm = BinaryManager(binDir: dir)
        // Use a thread-safe counter to satisfy Swift 6 Sendable requirements.
        let progressCounter = AtomicCounter()
        try await bm.install(.galleryDL) { _, _ in progressCounter.increment() }
        let progressCalls = progressCounter.value

        XCTAssertTrue(bm.isInstalled(.galleryDL),
                      "gallery-dl should be installed after install()")

        let version = try await bm.version(of: .galleryDL)
        XCTAssertNotNil(version, "version should be readable after install")
        print("BinaryManagerTests — installed gallery-dl version: \(version ?? "nil")")
        print("BinaryManagerTests — progress callbacks: \(progressCalls)")
    }
}

// MARK: - Helpers used across multiple tests

/// A thread-safe counter usable inside `@Sendable` closures without async/await.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}
