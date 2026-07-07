import Foundation

// MARK: - YtDlpAudioHook

/// Builds the production `youtubeAudioHook` for ``URLSessionDownloader`` — the
/// real yt-dlp path that downloads + extracts audio for YouTube and any other
/// yt-dlp-supported URL (SoundCloud, Vimeo, … — the generic Group-A path).
///
/// Without this, the downloader's default hook throws "not configured", so
/// non-direct-media URLs resolve + register but never actually download. Inject
/// `YtDlpAudioHook.make(mediaDir:)` wherever the production `URLSessionDownloader`
/// is constructed (e.g. `QueueController`).
///
/// Writes to the SAME layout the direct-media path uses
/// (`<mediaDir>/<slugify(showSlug)>/<slug>.mp3`) so the rest of the pipeline is
/// unchanged. Uses `yt-dlp --continue` (resume across retries — Group B) and
/// `--extract-audio --audio-format mp3` (needs ffmpeg). All process execution
/// goes through the hardened `Subprocess` (concurrent drain + kill-on-timeout).
public enum YtDlpAudioHook {

    /// The default wall-clock cap for one yt-dlp audio download. Generous because
    /// media can be large; `Subprocess` terminates the process if exceeded.
    public static let defaultTimeout: TimeInterval = 1800

    /// Make a `youtubeAudioHook` closure: `(Episode, URL) async throws -> URL`.
    /// Returns the local `.mp3` file URL on success.
    public static func make(
        mediaDir: URL,
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        timeout: TimeInterval = defaultTimeout,
        // (guid, showSlug, resolved media) — fired once per download when the
        // episode's title is still a raw URL, so the caller can backfill it.
        onMetadata: (@Sendable (String, String, ResolvedMedia) -> Void)? = nil
    ) -> @Sendable (Episode, URL) async throws -> URL {
        return { episode, url in
            // Resolve the managed yt-dlp binary (auto-installed elsewhere on first run).
            guard let ytdlpPath = binaryManager.resolvedPath(for: .ytDlp) else {
                throw PipelineError.permanent(
                    "yt-dlp not installed — required to download this URL. " +
                    "Install it from the first-run setup."
                )
            }
            // Audio extraction needs ffmpeg (detection-only — Homebrew).
            guard binaryManager.isInstalled(.ffmpeg) else {
                throw PipelineError.permanent(
                    "ffmpeg not found — required to extract audio. Install via Homebrew: brew install ffmpeg"
                )
            }

            // Destination mirrors URLSessionDownloader: <mediaDir>/<slug(show)>/<slug>.mp3
            let slug = URLSessionDownloader.makeSlug(episode)
            let showDir = mediaDir.appendingPathComponent(
                TextNormalization.slugify(episode.showSlug), isDirectory: true
            )
            let destURL = showDir.appendingPathComponent("\(slug).mp3")

            // Idempotent: a previous successful run already produced the file.
            if FileManager.default.fileExists(atPath: destURL.path) {
                return destURL
            }

            do {
                try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
            } catch {
                throw PipelineError.transient("Failed to create media directory: \(error)")
            }

            // yt-dlp writes <slug>.<ext>; --audio-format mp3 forces the final .mp3.
            let outTemplate = showDir.appendingPathComponent("\(slug).%(ext)s").path
            // N5: a pre-fix one-off persisted the raw pasted URL as its title.
            // When we spot that broken signature ("://" in the title) AND a
            // metadata sink is wired, ask yt-dlp to ALSO drop the info JSON next
            // to the audio — it rides on the download that is already happening
            // (no extra network round-trip) and lets us backfill the real
            // title/author/artwork. Good titles skip this entirely.
            let wantMeta = onMetadata != nil && episode.title.contains("://")
            let infoJSONURL = showDir.appendingPathComponent("\(slug).info.json")
            var args = YtDlp.hardenedBaseArgs + [
                "--continue",          // resume partial downloads across retries (Group B)
                "--no-playlist",       // a single item even if the URL also references a list
                "--no-progress",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "-o", outTemplate,
            ]
            if wantMeta { args += ["--write-info-json"] }
            args += ["--", url.absoluteString]

            Log.info("yt-dlp audio download starting",
                     component: "YtDlpAudioHook",
                     context: [("guid", episode.guid), ("url", url.absoluteString)])

            let result = try await subprocess.run(ytdlpPath, args, timeout: timeout)

            guard result.exitCode == 0 else {
                let tail = String(result.stderr.suffix(400))
                throw PipelineError.transient(
                    "yt-dlp exited \(result.exitCode) for \(url.absoluteString)\nstderr: \(tail)"
                )
            }

            guard FileManager.default.fileExists(atPath: destURL.path) else {
                throw PipelineError.transient(
                    "yt-dlp reported success but \(destURL.lastPathComponent) is missing"
                )
            }

            // N5 backfill: the download also wrote <slug>.info.json — parse the
            // real metadata and hand it to the sink (which updates the episode
            // title + the one-off show's title/author/artwork), then remove the
            // sidecar. Best-effort: any failure here must not fail the download.
            if wantMeta, let onMetadata,
               let data = try? Data(contentsOf: infoJSONURL),
               let json = String(data: data, encoding: .utf8),
               let media = try? MediaURLResolver.parse(json: json) {
                onMetadata(episode.guid, episode.showSlug, media)
                Log.info("yt-dlp metadata backfilled from download",
                         component: "YtDlpAudioHook",
                         context: [("guid", episode.guid), ("title", media.title)])
            }
            if wantMeta { try? FileManager.default.removeItem(at: infoJSONURL) }

            Log.info("yt-dlp audio download finished",
                     component: "YtDlpAudioHook",
                     context: [("guid", episode.guid), ("path", destURL.path)])
            return destURL
        }
    }
}
