import Foundation

// MARK: - YtDlpCaptionFetcher

/// Fetches a YouTube video's caption track (WebVTT) via yt-dlp, without
/// downloading the media. Used by the caption-source chain (see
/// ``CaptionFallback``) so a YouTube episode can be transcribed from its own
/// captions instead of running Whisper on the audio.
///
/// Everything is best-effort: any failure (yt-dlp missing, no captions in the
/// requested language, network error, empty file) returns `nil` so the caller
/// falls back to the next source in the chain (ultimately Whisper). It never
/// throws — the audio→Whisper path stays the safety net.
public enum YtDlpCaptionFetcher {

    /// Fetch captions and return the raw WebVTT text, or `nil` if none.
    ///
    /// - Parameters:
    ///   - videoURL: The YouTube (or yt-dlp-supported) video URL.
    ///   - auto: `false` = human/manually-provided subs (`--write-subs`);
    ///           `true` = YouTube's auto-generated subs (`--write-auto-subs`).
    ///   - langHint: BCP-47 language to request; `nil`/empty requests all
    ///     available languages and returns the first track found.
    public static func fetch(
        videoURL: String,
        auto: Bool,
        langHint: String?,
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        timeout: TimeInterval = 120
    ) async -> String? {
        guard !videoURL.isEmpty,
              let ytdlp = binaryManager.resolvedPath(for: .ytDlp) else { return nil }

        // Reject non-http(s) schemes and bare "-…" tokens (argument-injection
        // guard). This function never throws, so a rejected URL just falls
        // back to the next caption source (ultimately Whisper).
        guard let safe = try? URLSafety.safeURL(videoURL) else {
            Log.warn("YtDlpCaptionFetcher: rejected unsafe URL",
                     component: "Pipeline", context: [("url", videoURL)])
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocateca-caps-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outTemplate = tmp.appendingPathComponent("cap.%(ext)s").path

        // Resolve the caption language to request. NEVER "all": yt-dlp then pulls
        // ~150 languages sequentially and trips YouTube rate-limiting (HTTP 429).
        // Use the caller's hint, else the video's own language (one cheap --print),
        // else a bounded default. Requesting the video's language also yields the
        // ORIGINAL caption rather than a machine-translation.
        var langs = (langHint?.isEmpty == false) ? langHint! : ""
        if langs.isEmpty {
            if let meta = try? await subprocess.run(
                    ytdlp,
                    YtDlp.hardenedBaseArgs + ["--skip-download", "--no-playlist", "--print", "%(language)s", "--", safe],
                    timeout: 30),
               meta.exitCode == 0 {
                let vl = meta.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !vl.isEmpty, vl != "NA" { langs = vl }
            }
        }
        if langs.isEmpty { langs = "en,de" }

        var args = YtDlp.hardenedBaseArgs + [
            "--skip-download",             // captions only — no media
            "--no-playlist",
            "--no-progress",
            "--sub-format", "vtt/best",
            "--convert-subs", "vtt",       // normalise whatever format to VTT
            "--sub-langs", langs,
            "-o", outTemplate,
        ]
        args.append(auto ? "--write-auto-subs" : "--write-subs")
        args.append("--")
        args.append(safe)

        Log.debug("yt-dlp caption fetch",
                  component: "Captions",
                  context: [("auto", "\(auto)"), ("langs", langs)])

        guard let result = try? await subprocess.run(ytdlp, args, timeout: timeout),
              result.exitCode == 0 else { return nil }

        // yt-dlp writes cap.<lang>.vtt — take the first VTT produced.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil),
              let vttURL = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
              let vtt = try? String(contentsOf: vttURL, encoding: .utf8),
              !vtt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return vtt
    }
}
