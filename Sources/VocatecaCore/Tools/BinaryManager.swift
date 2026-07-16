import Foundation
import CryptoKit

// MARK: - Managed tool enum

/// The set of external binaries that `BinaryManager` knows about.
public enum ManagedTool: String, Sendable, CaseIterable {
    /// yt-dlp: self-managed, downloaded from GitHub releases.
    case ytDlp = "yt-dlp"
    /// gallery-dl: self-managed, downloaded from GitHub releases.
    case galleryDL = "gallery-dl"
    /// ffmpeg: self-managed — an arch-specific static build is downloaded (no
    /// Homebrew, no admin). An existing Homebrew ffmpeg is still honoured first.
    case ffmpeg
    /// ffprobe: self-managed alongside ffmpeg (yt-dlp's post-processing needs
    /// BOTH). Same eugeneware/ffmpeg-static release, arm64-only (Vocateca is
    /// Apple-Silicon-only). An existing Homebrew ffprobe is honoured first.
    case ffprobe
}

// MARK: - Errors

public enum BinaryManagerError: Error, Sendable, LocalizedError {
    /// The tool is not self-managed by this class (e.g. ffmpeg).
    case toolNotManaged(ManagedTool)
    /// The tool binary is absent or not executable.
    case notInstalled(ManagedTool)
    /// A network download failed.
    case downloadFailed(String)
    /// A subprocess returned a non-zero exit code or produced unexpected output.
    case subprocessFailed(String)
    /// The downloaded asset's SHA-256 did not match the pinned hash (H-1).
    /// The partial download is deleted before this is thrown.
    case checksumMismatch(tool: ManagedTool, expected: String, actual: String)

    /// Plain-English message consumed by `error.localizedDescription`.
    ///
    /// `VocatecaCore` has no localisation dependency (`L()` lives in
    /// `VocatecaUI`, which depends on Core, not the reverse — see
    /// `Package.swift`), so this is intentionally English-only. The
    /// UI layer (`FirstRunWizard.SetupStepModel`) pattern-matches
    /// `BinaryManagerError.checksumMismatch` specifically to show the
    /// localized user-facing string; every other case falls back to this
    /// description, matching the pre-existing (pre-hardening) behaviour for
    /// those cases.
    public var errorDescription: String? {
        switch self {
        case .toolNotManaged(let tool):
            return "\(tool.rawValue) is not self-installed by Vocateca."
        case .notInstalled(let tool):
            return "\(tool.rawValue) is not installed."
        case .downloadFailed(let reason):
            return "Download failed — \(reason)"
        case .subprocessFailed(let reason):
            return reason
        case .checksumMismatch(let tool, let expected, let actual):
            return "Checksum mismatch for \(tool.rawValue): expected \(expected), got \(actual)"
        }
    }
}

// MARK: - Pinned release table (H-1)
//
// Security hardening (2026-07-05): yt-dlp/gallery-dl were previously fetched
// from a floating `releases/latest` redirect with no integrity check beyond
// "file is non-empty" — see docs/audits/audit-security-report-2026-07-05.md
// finding H-1. Both tools are now pinned to a specific release tag + asset
// SHA-256, verified after every download. Bumping a pin is a one-line diff
// to this table; NEVER re-point at `releases/latest`.
//
// Pins recorded 2026-07-05:
//   yt-dlp 2026.07.04 — sha256 from the upstream `SHA2-256SUMS` release asset
//     (https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/SHA2-256SUMS),
//     independently re-verified by downloading `yt-dlp_macos` and hashing it.
//   gallery-dl v1.32.5 — upstream binary releases moved from GitHub to
//     Codeberg (github.com/mikf/gallery-dl/releases/latest now redirects to a
//     GitHub tag with ZERO assets — the old floating URL was already dead).
//     Codeberg publishes only a GPG `.sig` for `gallery-dl.bin`, no plaintext
//     checksum file, so the sha256 below was computed directly from the
//     asset at the pinned URL (github.com/mikf/gallery-dl/issues/9374 —
//     "Moving to Codeberg" announcement).
private struct PinnedRelease {
    let version: String
    let url: URL
    let sha256: String
}

private let pinnedReleases: [ManagedTool: PinnedRelease] = [
    .ytDlp: PinnedRelease(
        version: "2026.07.04",
        url: URL(string:
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp_macos"
        )!,
        sha256: "498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b"
    ),
    .galleryDL: PinnedRelease(
        version: "v1.32.5",
        url: URL(string:
            "https://codeberg.org/mikf/gallery-dl/releases/download/v1.32.5/gallery-dl.bin"
        )!,
        sha256: "9e9c432d0c90f11794d6e2555ca56c195efd08afdf988977c6e6ab671372049b"
    ),
]

// ffmpeg is arch-specific, so it can't live in the single-URL `pinnedReleases`.
// Source: eugeneware/ffmpeg-static release b6.1.1 — self-contained static
// binaries, already ad-hoc code-signed, so they run on Apple Silicon (AMFI)
// straight after download with NO admin, NO Homebrew, and no re-signing on our
// side. Hashes independently computed by downloading each asset (2026-07-10).
private let ffmpegPinsByArch: [String: PinnedRelease] = [
    "arm64": PinnedRelease(
        version: "b6.1.1",
        url: URL(string:
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64"
        )!,
        sha256: "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"
    ),
    "x86_64": PinnedRelease(
        version: "b6.1.1",
        url: URL(string:
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64"
        )!,
        sha256: "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894"
    ),
]

/// The running process's CPU arch (`"arm64"` | `"x86_64"`), for arch-specific
/// pins. Reads `uname(2)` — cheap, no allocation beyond the utsname buffer.
private func currentCPUArch() -> String {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    return machine.hasPrefix("arm64") ? "arm64" : "x86_64"
}

/// The pinned ffmpeg release for the current arch (nil on an unknown arch).
private func ffmpegPin() -> PinnedRelease? { ffmpegPinsByArch[currentCPUArch()] }

// ffprobe rides the SAME eugeneware/ffmpeg-static b6.1.1 release as ffmpeg
// (ad-hoc-signed → runs on Apple Silicon with no admin/Homebrew/re-signing).
// yt-dlp's audio post-processing needs ffprobe as well as ffmpeg, and the
// static ffmpeg build ships WITHOUT it — so a no-Homebrew user got only ffmpeg
// (2026-07-16). ARM64-ONLY on purpose: Vocateca does not support x86_64, so no
// Intel pin is carried (a Rosetta run would resolve `currentCPUArch()` to
// arm64 anyway). Hash independently computed by downloading the asset.
private let ffprobePinsByArch: [String: PinnedRelease] = [
    "arm64": PinnedRelease(
        version: "b6.1.1",
        url: URL(string:
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64"
        )!,
        sha256: "bb2db6f5d8cef919da12fbf592119a987202a8c060a886f3cab091f9cab90b64"
    ),
]

/// The pinned ffprobe release for the current arch (nil off arm64).
private func ffprobePin() -> PinnedRelease? { ffprobePinsByArch[currentCPUArch()] }

// MARK: - Download URLs

private extension ManagedTool {
    /// The pinned GitHub/Codeberg release asset URL for this tool's macOS
    /// standalone build. NEVER a `releases/latest` floating redirect (H-1) —
    /// see `pinnedReleases` above.
    /// The pinned release for this tool (arch-resolved for ffmpeg/ffprobe).
    var pinnedRelease: PinnedRelease? {
        switch self {
        case .ffmpeg:  return ffmpegPin()
        case .ffprobe: return ffprobePin()
        default:       return pinnedReleases[self]
        }
    }

    var downloadURL: URL {
        get throws {
            guard let pin = pinnedRelease else {
                throw BinaryManagerError.toolNotManaged(self)
            }
            return pin.url
        }
    }

    /// The pinned SHA-256 hex digest this tool's download must match.
    var expectedSHA256: String? { pinnedRelease?.sha256 }

    /// The version-flag arguments for this tool.
    var versionArgs: [String] {
        switch self {
        case .ytDlp:     return ["--version"]
        case .galleryDL: return ["--version"]
        case .ffmpeg:    return ["-version"]
        case .ffprobe:   return ["-version"]
        }
    }
}

// MARK: - Homebrew candidate paths for ffmpeg

private let homebrewFFmpegCandidates: [URL] = [
    URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),   // Apple Silicon
    URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),       // Intel Mac
    URL(fileURLWithPath: "/opt/local/bin/ffmpeg"),       // MacPorts
]

private let homebrewFFprobeCandidates: [URL] = [
    URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),  // Apple Silicon
    URL(fileURLWithPath: "/usr/local/bin/ffprobe"),      // Intel Mac
    URL(fileURLWithPath: "/opt/local/bin/ffprobe"),      // MacPorts
]

// MARK: - BinaryManager

/// Manages external binary tools (yt-dlp, gallery-dl, ffmpeg).
///
/// All three are downloaded on demand from pinned release URLs and stored in
/// `<userDataDir>/bin/`. They are chmod +x after download and atomically moved
/// into place so a partial download never leaves a broken binary. The downloaded
/// binaries are self-contained + already ad-hoc-signed, so they run with no
/// admin rights and no Homebrew.
///
/// ffmpeg additionally honours an existing Homebrew/MacPorts install first (so a
/// user who already has it doesn't get a second copy), then falls back to the
/// self-managed arch-specific static build.
public struct BinaryManager: Sendable {

    // MARK: - Properties

    /// The directory that holds self-managed binaries.
    public let binDir: URL

    private let subprocess: Subprocess

    // MARK: - Init

    public init(
        binDir: URL = Paths.userDataDir().appendingPathComponent("bin", isDirectory: true),
        subprocess: Subprocess = Subprocess()
    ) {
        self.binDir = binDir
        self.subprocess = subprocess
    }

    // MARK: - Path resolution

    /// Returns `<binDir>/<tool.rawValue>` regardless of whether the binary exists.
    public func managedPath(for tool: ManagedTool) -> URL {
        binDir.appendingPathComponent(tool.rawValue)
    }

    /// Returns the executable URL for `tool`, or `nil` if not found.
    ///
    /// - For yt-dlp: the bundled onedir inside the .app first (fast — see
    ///   `bundledYtDlpExecutable()`), then the managed download path, else nil.
    /// - For gallery-dl: the managed path if it exists and is executable.
    /// - For ffmpeg: managed path first, then Homebrew candidates, else nil.
    public func resolvedPath(for tool: ManagedTool) -> URL? {
        if tool == .ytDlp,
           let bundled = bundledYtDlpExecutable(),
           isExecutable(bundled),
           matchesCurrentArch(bundled) {
            Log.info("BinaryManager: yt-dlp resolved to bundled onedir (fast path)",
                     component: "BinaryManager", context: [("path", bundled.path)])
            return bundled
        }
        let managed = managedPath(for: tool)
        if isExecutable(managed) {
            if tool == .ytDlp {
                Log.info("BinaryManager: yt-dlp resolved to managed download",
                         component: "BinaryManager", context: [("path", managed.path)])
            }
            return managed
        }
        switch tool {
        case .ytDlp, .galleryDL:
            return nil
        case .ffmpeg:
            return homebrewFFmpegCandidates.first(where: isExecutable)
        case .ffprobe:
            return homebrewFFprobeCandidates.first(where: isExecutable)
        }
    }

    /// Path to the yt-dlp `--onedir` build bundled inside the signed .app at
    /// `Contents/Resources/tools/yt-dlp/yt-dlp` — see
    /// `packaging/build-ytdlp-onedir.sh` and `packaging/make-app-bundle.sh`.
    ///
    /// This is the perf fix: the onedir's files are deep-signed as part of
    /// the app and are trusted (scanned once) from first launch, unlike the
    /// managed-download onefile which self-extracts to a fresh unsigned temp
    /// dir on every exec (~10-15s cold start).
    ///
    /// `Bundle.main.resourceURL` is `nil` for `swift run` / unbundled dev
    /// builds, so this naturally returns `nil` there and falls through to
    /// the managed-download path — no behaviour change for dev.
    private func bundledYtDlpExecutable() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return resourceURL
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: false)
    }

    /// Cheap Mach-O arch guard for the bundled onedir: the build currently
    /// ships HOST-arch-only (arm64 on Apple Silicon — see
    /// build-ytdlp-onedir.sh), so on an Intel Mac the bundled binary would
    /// be unusable. Rather than spawn a subprocess (slow, and this function
    /// must never hang a sync call), this reads only the 8-byte Mach-O
    /// header and compares `cputype` against the current process arch.
    ///
    /// Fails OPEN (returns `true`) for anything it can't confidently parse
    /// (fat binaries, unreadable files, unexpected magic) — those cases fall
    /// through to whichever caller actually invokes the binary, where an
    /// exec failure is handled normally; this guard only needs to catch the
    /// common, cheap-to-detect case of a thin arm64 executable on x86_64.
    private func matchesCurrentArch(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return true }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return true }

        let magic = Self.readUInt32LE(header, at: 0)
        let cputype = Self.readUInt32LE(header, at: 4)

        let machMagic64: UInt32 = 0xfeedfacf   // MH_MAGIC_64 (thin, native-endian)
        let cpuTypeARM64: UInt32 = 0x0100_000c
        let cpuTypeX86_64: UInt32 = 0x0100_0007

        guard magic == machMagic64 else { return true }   // fat/unknown — fail open

        switch currentCPUArch() {
        case "arm64":  return cputype == cpuTypeARM64
        case "x86_64": return cputype == cpuTypeX86_64
        default:       return true
        }
    }

    /// Reads 4 bytes of `data` starting at `offset` as a little-endian
    /// `UInt32`, without relying on `Data`'s memory alignment (avoids the
    /// trap risk of `withUnsafeBytes { $0.load(as:) }` on an unaligned slice).
    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Returns `true` when `resolvedPath(for:)` is non-nil.
    public func isInstalled(_ tool: ManagedTool) -> Bool {
        resolvedPath(for: tool) != nil
    }

    /// Returns the set of **required** tools that are not currently installed.
    ///
    /// "Required" means the pipeline cannot function without them:
    /// - `yt-dlp` — needed for YouTube and generic URL downloads.
    /// - `ffmpeg` — needed for audio extraction from video files.
    /// - `ffprobe` — yt-dlp's audio post-processing needs it alongside ffmpeg;
    ///   the static ffmpeg build ships without it, so it's tracked separately
    ///   (2026-07-16).
    ///
    /// `gallery-dl` is NOT included here (Instagram is optional).
    /// `whisper-cli` / WhisperKit is checked separately by the transcription engine.
    ///
    /// This check is **cheap** (no network, no subprocess) — it only tests
    /// whether the binary exists and is executable. Safe to call at launch.
    ///
    /// - Returns: Array of ``ManagedTool`` values that are missing.
    public func requiredToolsMissing() -> [ManagedTool] {
        let required: [ManagedTool] = [.ytDlp, .ffmpeg, .ffprobe]
        return required.filter { !isInstalled($0) }
    }

    // MARK: - Version

    /// Runs the tool and returns its version string, or `nil` if the tool is
    /// not installed.
    ///
    /// - Throws: `BinaryManagerError.subprocessFailed` when the tool exits
    ///   non-zero and we cannot parse a version from its output.
    public func version(of tool: ManagedTool) async throws -> String? {
        guard let path = resolvedPath(for: tool) else { return nil }
        let result = try await subprocess.run(path, tool.versionArgs, timeout: 30)
        // ffmpeg writes its banner to stdout; yt-dlp and gallery-dl to stdout.
        let combined = result.stdout + result.stderr
        return Self.parseVersion(toolOutput: combined, for: tool)
    }

    // MARK: - Version parsing (pure — testable without IO)

    /// Parse the version string from the combined stdout + stderr of the tool.
    ///
    /// - yt-dlp:     bare `2025.01.01` on the first line of stdout.
    /// - gallery-dl: bare `1.27.0` on the first line of stdout.
    /// - ffmpeg:     `ffmpeg version 6.1.1 ...` — extract the token after "version".
    public static func parseVersion(toolOutput: String, for tool: ManagedTool) -> String? {
        let lines = toolOutput.components(separatedBy: .newlines)
        switch tool {
        case .ytDlp, .galleryDL:
            // First non-empty line is the bare version.
            return lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .ffmpeg, .ffprobe:
            // First line: "ffmpeg version <X> …" / "ffprobe version <X> …"
            // We want the token immediately after the word "version".
            for line in lines {
                let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = tokens.firstIndex(of: "version"), tokens.indices.contains(idx + 1) {
                    return tokens[idx + 1]
                }
            }
            return nil
        }
    }

    // MARK: - Install

    /// Downloads and installs `tool` to `binDir`.
    ///
    /// Progress is reported as `(bytesReceived, totalBytes)` where `totalBytes`
    /// may be 0 if the server does not send `Content-Length`.
    ///
    /// After download, the file's SHA-256 is compared against the pinned hash
    /// in `pinnedReleases` (H-1 fix). On mismatch the partial file is deleted
    /// and `BinaryManagerError.checksumMismatch` is thrown — this NEVER installs
    /// an unverified binary.
    ///
    /// - Throws: `BinaryManagerError.toolNotManaged` for ffmpeg.
    ///   `BinaryManagerError.downloadFailed` on network or empty-file errors.
    ///   `BinaryManagerError.checksumMismatch` when the SHA-256 doesn't match.
    public func install(
        _ tool: ManagedTool,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let downloadURL = try tool.downloadURL   // throws for ffmpeg
        let destination = managedPath(for: tool)

        // Ensure the bin directory exists.
        try FileManager.default.createDirectory(
            at: binDir,
            withIntermediateDirectories: true
        )

        // Download to a temp file in the same directory so the atomic rename
        // stays on the same filesystem and never crosses a volume boundary.
        let tmpURL = binDir.appendingPathComponent("\(tool.rawValue).part")

        // Clean up any stale partial download from a previous interrupted run.
        try? FileManager.default.removeItem(at: tmpURL)

        do {
            let (localURL, totalBytes) = try await downloadWithProgress(
                url: downloadURL,
                destination: tmpURL,
                progress: progress
            )

            // Verify non-empty.
            let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let size = (attrs[.size] as? Int64) ?? 0
            guard size > 0 else {
                try? FileManager.default.removeItem(at: tmpURL)
                throw BinaryManagerError.downloadFailed("Downloaded file is empty (0 bytes)")
            }
            _ = totalBytes  // already used in progress; silence unused warning

            // SHA-256 verification against the pinned hash (H-1). Every managed
            // tool in `pinnedReleases` has an expected hash, so this always runs
            // for yt-dlp/gallery-dl; a tool with no pin (shouldn't happen —
            // `downloadURL` already throws first) would skip verification.
            if let expected = tool.expectedSHA256 {
                let data = try Data(contentsOf: tmpURL)
                let actual = Self.sha256Hex(of: data)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    Log.error("BinaryManager: checksum mismatch — download rejected",
                              component: "BinaryManager",
                              context: [("tool", tool.rawValue), ("expected", expected), ("actual", actual)])
                    throw BinaryManagerError.checksumMismatch(tool: tool, expected: expected, actual: actual)
                }
                Log.info("BinaryManager: checksum verified",
                         component: "BinaryManager",
                         context: [("tool", tool.rawValue), ("sha256", actual)])
            }

            // chmod +x
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755 as NSNumber],
                ofItemAtPath: tmpURL.path
            )

            // Atomic replace.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
        } catch let e as BinaryManagerError {
            try? FileManager.default.removeItem(at: tmpURL)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw BinaryManagerError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Hash verification (pure — testable without IO)

    /// Returns the lowercase hex SHA-256 digest of `data`.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Self-update
    //
    // POLICY (H-1): self-update NEVER runs the tool's own `-U`/`--update`
    // mechanism — that would fetch and execute an arbitrary future release
    // with no hash pin, defeating the whole point of `pinnedReleases`. The
    // only sanctioned way to move to a newer version is bumping the pinned
    // `(version, url, sha256)` tuple in `pinnedReleases` and re-running the
    // normal `install()` path. `selfUpdate` below simply re-installs the
    // CURRENT pin (useful to repair a corrupted/tampered local binary); it
    // can never move the app off the reviewed pin.

    /// Re-installs `tool` from the current pinned, hash-verified release.
    /// This is NOT an update mechanism — it re-fetches and re-verifies the
    /// SAME pin recorded in `pinnedReleases`. To move to a newer release,
    /// bump the pin in source and ship a new app version.
    public func selfUpdate(_ tool: ManagedTool) async throws {
        Log.info("BinaryManager: re-installing pinned release (never -U)",
                 component: "BinaryManager", context: [("tool", tool.rawValue)])
        try await install(tool)
    }

    // MARK: - Private helpers

    private func isExecutable(_ url: URL) -> Bool {
        let path = url.path
        return FileManager.default.fileExists(atPath: path)
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Downloads `url` to `destination`, calling `progress` periodically.
    /// Returns `(destination, totalBytes)`.
    private func downloadWithProgress(
        url: URL,
        destination: URL,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> (URL, Int64) {
        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .vocateca(requestTimeout: 60, resourceTimeout: 1800))
            let task = session.downloadTask(with: url) { tmpURL, response, error in
                if let error {
                    continuation.resume(throwing: BinaryManagerError.downloadFailed(
                        error.localizedDescription
                    ))
                    return
                }
                guard let tmpURL else {
                    continuation.resume(throwing: BinaryManagerError.downloadFailed(
                        "No temporary file returned by URLSession"
                    ))
                    return
                }
                do {
                    // URLSession writes to a system temp; move it to our destination.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: destination)
                    let total = (response as? HTTPURLResponse)
                        .flatMap { $0.expectedContentLength == -1 ? nil : Optional($0.expectedContentLength) }
                        ?? 0
                    continuation.resume(returning: (destination, Int64(total)))
                } catch {
                    continuation.resume(throwing: BinaryManagerError.downloadFailed(
                        error.localizedDescription
                    ))
                }
            }

            // Wire up progress reporting if a callback was provided.
            if let progress {
                let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                    let total = p.totalUnitCount
                    let done  = p.completedUnitCount
                    progress(done, total)
                }
                // Keep the observation alive for the lifetime of the task by
                // storing it in a local that is retained by the closure below.
                task.resume()
                _ = observation   // retain until task completion path runs
            } else {
                task.resume()
            }
        }
    }
}
