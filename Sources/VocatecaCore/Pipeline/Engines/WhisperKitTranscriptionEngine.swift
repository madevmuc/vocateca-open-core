import Foundation

// MARK: - TranscriptionArtifacts

/// The outputs produced by `WhisperKitTranscriptionEngine` for one episode.
/// Consumed by `MarkdownLibraryWriter`.
public struct TranscriptionArtifacts: Sendable {
    /// Full transcript text (plain, no timestamps).
    public let text: String
    /// SRT-formatted caption file content.
    public let srtContent: String
    /// Markdown file content (frontmatter + banner + body).
    public let markdownContent: String
    /// Number of whitespace-delimited tokens in `text`.
    public let wordCount: Int
    /// Mean segment confidence from WhisperKit (nil if not available).
    public let meanConfidence: Double?
    /// Detected language (BCP-47), from WhisperKit or nil.
    public let detectedLanguage: String?
}

// MARK: - WhisperKitTranscriptionEngine

/// Higher-level transcription engine that:
/// 1. Optionally converts non-native audio via ffmpeg (WAV 16 kHz mono PCM).
/// 2. Runs `WhisperKitTranscriber.transcribe`.
/// 3. Builds `.srt` and `.md` artifacts from the result.
///
/// Gate real-model tests behind `VOCATECA_RUN_WHISPER_TESTS=1`.
///
/// ## ffmpeg conversion
/// Only triggered when `TranscriptFormat.isWhisperNativeAudio(headerBytes:)` returns
/// `false` (i.e. not WAV/MP3/FLAC). If ffmpeg is not resolved by `BinaryManager`,
/// the engine throws `PipelineError.permanent` rather than silently skipping
/// conversion — a format whisper cannot decode should fail loudly.
///
/// ## YouTube audio decision
/// This engine does NOT handle YouTube download; it assumes `audioURL` is already
/// a local file (mp3 / wav / m4a) produced by `URLSessionDownloader` or the
/// yt-dlp hook. The YouTube-audio yt-dlp delegation lives in `URLSessionDownloader`.
public struct WhisperKitTranscriptionEngine: Sendable {

    // MARK: - Dependencies

    private let transcriber: WhisperKitTranscriber
    private let binaryManager: BinaryManager
    private let subprocess: Subprocess

    // MARK: - Init

    public init(
        transcriber: WhisperKitTranscriber = WhisperKitTranscriber(),
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess()
    ) {
        self.transcriber = transcriber
        self.binaryManager = binaryManager
        self.subprocess = subprocess
    }

    // MARK: - Transcribe

    /// Transcribes `audioURL` and builds all library artifacts for `episode`.
    ///
    /// - Parameters:
    ///   - audioURL: Local `file://` URL of the downloaded audio.
    ///   - episode: Episode metadata used for frontmatter / markdown rendering.
    ///   - source: `"podcast"` or `"youtube"` — controls which format function is used.
    /// - Returns: `TranscriptionArtifacts` ready for `MarkdownLibraryWriter`.
    /// - Throws: `PipelineError` on ffmpeg / whisper / timeout failures.
    public func transcribe(
        audioURL: URL,
        episode: Episode,
        source: String = "podcast"
    ) async throws -> TranscriptionArtifacts {

        // 1. Decide whether ffmpeg conversion is needed.
        let audioToTranscribe = try await prepareAudio(audioURL: audioURL)
        defer {
            // Clean up temp WAV if we created one.
            if audioToTranscribe != audioURL {
                try? FileManager.default.removeItem(at: audioToTranscribe)
            }
        }

        // 2. Compute timeout from file size (mirrors Python heuristic).
        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        let timeoutSeconds = TranscriptFormat.whisperTimeoutSeconds(fileSizeBytes: fileSize)

        // 3. Run WhisperKit transcription with timeout.
        let result: TranscriptionResult
        do {
            result = try await withTimeout(seconds: Double(timeoutSeconds)) {
                try await self.transcriber.transcribe(
                    audioURL: audioToTranscribe,
                    language: episode.detectedLanguage
                )
            }
        } catch is TimeoutError {
            throw PipelineError.transient("Whisper transcription timed out after \(timeoutSeconds)s")
        } catch {
            throw PipelineError.permanent("Whisper transcription failed: \(error)")
        }

        // 4. Build SRT.
        let srtContent = Self.buildSRT(segments: result.segments)

        // 5. Build markdown via TranscriptFormat (matches Python render_episode_markdown or frontmatter).
        let markdownContent: String
        if source == "youtube" {
            markdownContent = TranscriptFormat.renderEpisodeMarkdown(
                showSlug: episode.showSlug,
                title: episode.title,
                srtText: srtContent,
                source: "youtube",
                youtubeID: nil,          // caller may enrich if needed
                pubDate: episode.pubDate
            )
        } else {
            // Podcast path: use whisper frontmatter + banner + plain transcript body.
            let fm = TranscriptFormat.frontmatter(
                meta: [
                    "guid":      episode.guid,
                    "show_slug": episode.showSlug,
                    "title":     episode.title,
                    "pub_date":  episode.pubDate,
                    "mp3_url":   episode.mp3Url,
                ],
                detectedLanguage: result.language
            )
            let bannerStr = TranscriptFormat.banner(pubDate: episode.pubDate)
            let body = TranscriptFormat.srtToPlainText(srtContent)
            markdownContent = fm + bannerStr + body + "\n"
        }

        // 6. Compute word count and mean confidence.
        let wordCount = Self.countWords(result.text)
        let meanConfidence: Double? = Self.computeMeanConfidence(result.segments)

        return TranscriptionArtifacts(
            text: result.text,
            srtContent: srtContent,
            markdownContent: markdownContent,
            wordCount: wordCount,
            meanConfidence: meanConfidence,
            detectedLanguage: result.language
        )
    }

    // MARK: - SRT builder

    /// Builds SRT content from `TranscriptionSegment` array.
    ///
    /// Format (matches Python SRT output exactly):
    /// ```
    /// 1
    /// HH:MM:SS,mmm --> HH:MM:SS,mmm
    /// segment text
    ///
    /// 2
    /// ...
    /// ```
    /// The final segment block ends with a trailing blank line (joining with "\n"
    /// produces a trailing "\n").
    public static func buildSRT(segments: [TranscriptionSegment]) -> String {
        var parts: [String] = []
        for (index, seg) in segments.enumerated() {
            parts.append(String(index + 1))
            parts.append("\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))")
            parts.append(seg.text)
            parts.append("")   // blank line separator
        }
        return parts.joined(separator: "\n")
    }

    /// Format seconds as `HH:MM:SS,mmm` (SRT timestamp).
    public static func formatSRTTime(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let ms  = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let totalMin = totalSec / 60
        let min = totalMin % 60
        let hour = totalMin / 60
        return String(format: "%02d:%02d:%02d,%03d", hour, min, sec, ms)
    }

    // MARK: - Word count

    /// Count whitespace-delimited tokens, mirroring Python `len(text.split())`.
    public static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Mean confidence

    /// Average confidence across segments. `TranscriptionSegment` doesn't carry
    /// per-segment confidence (WhisperKit exposes it in `TranscriptionResult.avgLogprob`
    /// per window, not per segment in the domain type). Returns nil for now.
    ///
    /// Extension point: if `TranscriptionSegment` is extended with a `confidence`
    /// field, average here.
    public static func computeMeanConfidence(_ segments: [TranscriptionSegment]) -> Double? {
        // TranscriptionSegment has no confidence field in the current domain type.
        return nil
    }

    // MARK: - ffmpeg conversion

    /// Returns `audioURL` unchanged if it is already Whisper-native; otherwise
    /// converts to a 16 kHz mono PCM WAV via ffmpeg and returns the temp WAV URL.
    private func prepareAudio(audioURL: URL) async throws -> URL {
        // Read the first 16 bytes to sniff the format.
        let headerBytes: [UInt8]
        do {
            let handle = try FileHandle(forReadingFrom: audioURL)
            let data = handle.readData(ofLength: 16)
            try handle.close()
            headerBytes = Array(data)
        } catch {
            throw PipelineError.permanent("Cannot read audio file header: \(error)")
        }

        if TranscriptFormat.isWhisperNativeAudio(headerBytes: headerBytes) {
            return audioURL   // already native — no conversion needed
        }

        // Need ffmpeg conversion.
        guard let ffmpegPath = binaryManager.resolvedPath(for: .ffmpeg) else {
            throw PipelineError.permanent(
                "ffmpeg not found but audio format requires conversion " +
                "(header bytes: \(headerBytes.prefix(4).map { String(format: "%02x", $0) }.joined())). " +
                "Install ffmpeg via Homebrew: brew install ffmpeg"
            )
        }

        // Write temp WAV next to the source file.
        let tmpWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocateca-\(UUID().uuidString).wav")

        let args = [
            "-y",            // overwrite without prompting
            "-i", audioURL.path,
            "-ar", "16000",  // 16 kHz sample rate (WhisperKit requirement)
            "-ac", "1",      // mono
            "-c:a", "pcm_s16le",
            tmpWAV.path
        ]

        let result = try await subprocess.run(ffmpegPath, args, timeout: 300)
        if result.exitCode != 0 {
            throw PipelineError.permanent(
                "ffmpeg conversion failed (exit \(result.exitCode)): \(result.stderr)"
            )
        }

        return tmpWAV
    }
}

// MARK: - Timeout helper
//
// The `withTimeout` / `TimeoutError` used above now live in the shared
// `Tools/Timeout.swift` (hoisted for H6 so all three transcription engines share
// one implementation); this file's private copies were removed. The dead
// `transcribe` path above is retained only for its still-referenced static SRT
// helpers (`buildSRT`/`formatSRTTime`/`countWords`/`computeMeanConfidence`) —
// do NOT wire it back into the pipeline.
