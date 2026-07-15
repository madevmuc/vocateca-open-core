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

        Log.debug("yt-dlp caption fetch",
                  component: "Captions",
                  context: [("auto", "\(auto)"), ("langs", langs)])

        return await downloadSubtitle(
            ytdlp: ytdlp, safeVideoURL: safe, auto: auto, langs: langs, outTemplate: outTemplate,
            subprocess: subprocess, timeout: timeout)
    }

    // MARK: - listManifest(videoURL:)

    /// Lists a video's available caption tracks (manual + auto) AND its
    /// metadata (title/channel/original language) via a SINGLE
    /// `yt-dlp --dump-json` probe — never downloads any subtitle content.
    ///
    /// This is the fix for the P-perf bug: the Explorer used to make THREE
    /// separate yt-dlp invocations per video load (a `--print` metadata
    /// probe, a `--dump-json` caption manifest probe, and a `--sub-langs`
    /// caption download) — and yt-dlp's packaged binary has a ~9-10s cold
    /// start PER invocation, so that was ~30s for one video. A single
    /// `--dump-json` already contains everything: `id`/`title`/
    /// `channel_id`/`uploader_id`/`language` AND the `subtitles`/
    /// `automatic_captions` manifest — including, per track, a direct
    /// HTTP(S) URL for the `vtt` format (see ``CaptionTrack/url``) that's
    /// fetchable without yt-dlp at all (see
    /// ``fetchTrackViaHTTP(_:session:timeout:)``). Collapsing all three
    /// probes into this one call, plus a direct HTTP GET for the chosen
    /// track's VTT, removes 2 of the 3 ~10s cold starts.
    ///
    /// ``listTracks(videoURL:binaryManager:subprocess:timeout:)`` is now a
    /// thin wrapper around this that discards `meta` — kept for callers that
    /// only need the track list.
    ///
    /// - Parameter timeout: hard wall-clock timeout for the probe. On
    ///   timeout (or any other failure) this returns `(nil, [])`, never
    ///   hangs and never throws — the caller falls back to the next caption
    ///   source (ultimately Whisper).
    public static func listManifest(
        videoURL: String,
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        // The managed yt-dlp is the PyInstaller `yt-dlp_macos` onefile, which
        // pays a large cold-start tax per exec (self-extraction + first-run
        // scanning of the unpacked payload — measured ~10s, and worse on
        // machines with aggressive endpoint security). 15s was too tight: a
        // slow start made the single manifest probe time out and the caller
        // fall through to a full local ASR transcription (tens of seconds)
        // for a video that HAS captions. Give the probe real headroom so a
        // slow-starting yt-dlp never gets misread as "no captions".
        timeout: TimeInterval = 60
    ) async -> (meta: YouTubeVideoMeta?, tracks: [CaptionTrack]) {
        guard !videoURL.isEmpty,
              let ytdlp = binaryManager.resolvedPath(for: .ytDlp) else { return (nil, []) }

        guard let safe = try? URLSafety.safeURL(videoURL) else {
            Log.warn("YtDlpCaptionFetcher.listManifest: rejected unsafe URL",
                     component: "Pipeline", context: [("url", videoURL)])
            return (nil, [])
        }

        let args = YtDlp.hardenedBaseArgs + [
            "--skip-download", "--no-playlist", "--no-warnings",
            "--dump-json", "--", safe,
        ]

        Log.debug("yt-dlp manifest+meta probe", component: "Captions", context: [("url", safe)])

        guard let result = try? await subprocess.run(ytdlp, args, timeout: timeout),
              result.exitCode == 0 else {
            Log.warn("YtDlpCaptionFetcher.listManifest: probe failed or timed out",
                     component: "Captions", context: [("url", safe)])
            return (nil, [])
        }

        // `--dump-json` (no --flat-playlist, single video) prints one JSON
        // object; take the first non-blank line defensively, same pattern as
        // `YtDlpVideoMetadataFetcher.fetchMeta`.
        let line = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? result.stdout

        let parsed = parseManifestLine(line)
        Log.debug("yt-dlp manifest+meta parsed", component: "Captions",
                  context: [("url", safe), ("tracks", "\(parsed.tracks.count)"), ("hasMeta", "\(parsed.meta != nil)")])
        return parsed
    }

    // MARK: - listTracks(videoURL:)

    /// Lists a video's available caption tracks (manual + auto), discarding
    /// the metadata half of ``listManifest(videoURL:binaryManager:subprocess:timeout:)``
    /// — for callers that only need the track list (e.g. a caption-language
    /// picker that already has metadata from elsewhere).
    ///
    /// - Parameter timeout: hard wall-clock timeout for the manifest probe.
    ///   On timeout (or any other failure) this returns `[]`, never hangs
    ///   and never throws — the caller falls back to the next caption
    ///   source (ultimately Whisper).
    public static func listTracks(
        videoURL: String,
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        timeout: TimeInterval = 15
    ) async -> [CaptionTrack] {
        await listManifest(videoURL: videoURL, binaryManager: binaryManager,
                            subprocess: subprocess, timeout: timeout).tracks
    }

    /// Parses a single `yt-dlp --dump-json` output line into video metadata
    /// (`id`/`title`/`channel_id`/`uploader_id`/`language`) plus the
    /// `subtitles`/`automatic_captions` dictionaries as ``CaptionTrack``s.
    /// Pure, no I/O — internal so tests can hit it directly without a
    /// subprocess.
    ///
    /// Manual (`subtitles`) tracks are listed before auto
    /// (`automatic_captions`) tracks; each dictionary is iterated in
    /// language-code sorted order for deterministic output (`Dictionary`
    /// iteration order is otherwise unspecified). Each track's ``CaptionTrack/url``
    /// is the `ext == "vtt"` format entry's `url` when present, else `nil`.
    /// Returns `(nil, [])` on any unparsable input.
    static func parseManifestLine(_ line: String) -> (meta: YouTubeVideoMeta?, tracks: [CaptionTrack]) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return (nil, []) }

        func stringValue(_ key: String) -> String? {
            guard case .string(let s)? = root[key] else { return nil }
            return s
        }
        func presentOrNil(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s != "NA" else { return nil }
            return s
        }

        let videoID = stringValue("id") ?? ""
        let meta: YouTubeVideoMeta? = videoID.isEmpty ? nil : YouTubeVideoMeta(
            videoID: videoID,
            title: stringValue("title") ?? "",
            channelID: presentOrNil(stringValue("channel_id")),
            channelHandle: presentOrNil(stringValue("uploader_id")),
            language: presentOrNil(stringValue("language")))

        func tracks(from key: String, isAuto: Bool) -> [CaptionTrack] {
            guard case .object(let langs)? = root[key] else { return [] }
            var result: [CaptionTrack] = []
            for lang in langs.keys.sorted() {
                var name = lang
                var vttURL: String? = nil
                if case .array(let formats)? = langs[lang] {
                    if case .object(let first)? = formats.first,
                       case .string(let n)? = first["name"] {
                        name = n
                    }
                    for case .object(let fmt) in formats {
                        if case .string(let ext)? = fmt["ext"], ext == "vtt",
                           case .string(let u)? = fmt["url"] {
                            vttURL = u
                            break
                        }
                    }
                }
                result.append(CaptionTrack(languageCode: lang, displayName: name, isAuto: isAuto, url: vttURL))
            }
            return result
        }

        let tracks = tracks(from: "subtitles", isAuto: false) + tracks(from: "automatic_captions", isAuto: true)
        return (meta, tracks)
    }

    // MARK: - fetchTrack(videoURL:track:)

    /// Fetches exactly ONE already-selected caption track (from
    /// ``listTracks(videoURL:binaryManager:subprocess:timeout:)`` +
    /// ``CaptionLanguageMatcher``) and returns its raw WebVTT text, or `nil`
    /// on any failure.
    ///
    /// Requests ONLY `track.languageCode` via `--sub-langs` — never "all"/
    /// unconstrained — so this is always a single, bounded download
    /// regardless of how many tracks the video's manifest lists.
    ///
    /// - Parameter timeout: hard wall-clock timeout for the fetch. On
    ///   timeout (or any other failure) this returns `nil`, never hangs and
    ///   never throws.
    public static func fetchTrack(
        videoURL: String,
        track: CaptionTrack,
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        timeout: TimeInterval = 20
    ) async -> String? {
        guard !videoURL.isEmpty,
              let ytdlp = binaryManager.resolvedPath(for: .ytDlp) else { return nil }

        guard let safe = try? URLSafety.safeURL(videoURL) else {
            Log.warn("YtDlpCaptionFetcher.fetchTrack: rejected unsafe URL",
                     component: "Pipeline", context: [("url", videoURL)])
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocateca-caps-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outTemplate = tmp.appendingPathComponent("cap.%(ext)s").path

        Log.debug("yt-dlp caption track fetch", component: "Captions",
                  context: [("auto", "\(track.isAuto)"), ("language", track.languageCode)])

        guard let vtt = await downloadSubtitle(
            ytdlp: ytdlp, safeVideoURL: safe, auto: track.isAuto, langs: track.languageCode,
            outTemplate: outTemplate, subprocess: subprocess, timeout: timeout)
        else {
            Log.warn("YtDlpCaptionFetcher.fetchTrack: yt-dlp failed, timed out, or produced no VTT",
                     component: "Captions", context: [("language", track.languageCode)])
            return nil
        }
        return vtt
    }

    // MARK: - fetchTrackViaHTTP(_:)

    /// Fetches a caption track's WebVTT content via a direct HTTP GET on
    /// ``CaptionTrack/url`` — NO yt-dlp subprocess. This is the main perf
    /// win: yt-dlp's packaged binary has a ~9-10s cold start per invocation,
    /// while the `url` yt-dlp already minted while building the manifest
    /// (see ``listManifest(videoURL:binaryManager:subprocess:timeout:)``) is
    /// directly fetchable (verified: a plain `curl` on it returns valid
    /// WEBVTT in ~0.23s).
    ///
    /// Goes through ``URLSafety/boundedData(from:maxBytes:timeout:userAgent:session:)``
    /// so the fetch gets the same SSRF-redirect-validation and size-cap
    /// treatment as every other network fetch in the app, even though
    /// `track.url` originates from yt-dlp rather than untrusted input.
    ///
    /// - Returns: `nil` if `track.url` is `nil`/empty, the URL fails the
    ///   safety check, the request fails/times out, or the body doesn't
    ///   look like WebVTT (doesn't start with `"WEBVTT"`) — the caller
    ///   falls back to
    ///   ``fetchTrack(videoURL:track:binaryManager:subprocess:timeout:)``.
    public static func fetchTrackViaHTTP(
        _ track: CaptionTrack,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async -> String? {
        guard let urlString = track.url, !urlString.isEmpty else { return nil }

        guard let safe = try? URLSafety.safeURL(urlString), let url = URL(string: safe) else {
            Log.warn("YtDlpCaptionFetcher.fetchTrackViaHTTP: rejected unsafe URL",
                     component: "Pipeline", context: [("url", urlString)])
            return nil
        }

        do {
            let data = try await URLSafety.boundedData(
                from: url, maxBytes: Self.maxCaptionBytes, timeout: timeout, session: session)
            guard let text = String(data: data, encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
            else {
                Log.warn("YtDlpCaptionFetcher.fetchTrackViaHTTP: response was not WebVTT",
                         component: "Captions", context: [("language", track.languageCode)])
                return nil
            }
            return text
        } catch {
            Log.warn("YtDlpCaptionFetcher.fetchTrackViaHTTP: request failed",
                     component: "Captions", context: [("language", track.languageCode), ("error", "\(error)")])
            return nil
        }
    }

    /// Caption files are plain text and small (a feature-length video's VTT
    /// is a few hundred KB at most) — 10 MB is a generous cap that still
    /// protects against a pathological/malicious response.
    private static let maxCaptionBytes = 10 * 1024 * 1024

    // MARK: - Shared download logic

    /// Runs yt-dlp with `--sub-langs langs` and either `--write-subs` or
    /// `--write-auto-subs`, and returns the first `.vtt` file it produces
    /// (yt-dlp writes `cap.<lang>.vtt` against `outTemplate`). Shared by
    /// `fetch(videoURL:auto:langHint:...)` (bounded multi-language fallback)
    /// and `fetchTrack(videoURL:track:...)` (single, already-resolved
    /// track) — identical download/collection mechanics, only `langs`/`auto`
    /// differ.
    private static func downloadSubtitle(
        ytdlp: URL,
        safeVideoURL: String,
        auto: Bool,
        langs: String,
        outTemplate: String,
        subprocess: Subprocess,
        timeout: TimeInterval
    ) async -> String? {
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
        args.append(safeVideoURL)

        guard let result = try? await subprocess.run(ytdlp, args, timeout: timeout),
              result.exitCode == 0 else { return nil }

        // yt-dlp writes cap.<lang>.vtt — take the first VTT produced.
        let tmp = URL(fileURLWithPath: outTemplate).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil),
              let vttURL = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
              let vtt = try? String(contentsOf: vttURL, encoding: .utf8),
              !vtt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return vtt
    }
}
