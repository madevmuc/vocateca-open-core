import Foundation

/// Oracle-locked ports of transcript format pure functions from
/// `core/transcriber.py`, `core/export.py`, and `core/youtube_captions.py`.
///
/// Every deterministic function must produce **byte-for-byte identical output**
/// to the Python reference implementation for all inputs in the golden fixture
/// files at `Tests/VocatecaCoreTests/Fixtures/oracle/`.
///
/// The now()-dependent functions (`frontmatter`, `banner`, `renderEpisodeMarkdown`)
/// accept injected `now:` / `transcribedAt:` parameters so they are fully
/// deterministic when pinned; callers that want "real now" use the defaults.
///
/// Do NOT change these algorithms without regenerating the golden fixtures and
/// running `swift test --filter OracleTranscriptTests`.
public enum TranscriptFormat: Sendable {

    // MARK: - parseDetectedLanguage
    // Port of `parse_detected_language(text)` from `core/transcriber.py`.
    // Regex: r"auto-detected language:\s*([a-z]{2,3})"
    // Returns the ISO 639 language code found in a whisper-cli stderr log line,
    // or nil when the input is empty or the pattern is absent.

    /// Extracts the ISO language code from a whisper-cli auto-detect log line.
    ///
    /// Oracle-locked port of `parse_detected_language(text)` from `core/transcriber.py`.
    /// Regex: `auto-detected language:\s*([a-z]{2,3})`.
    public static func parseDetectedLanguage(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        // NSRegularExpression is used to match Python's `re.search` semantics.
        // Pattern matches anywhere in the string.
        guard let re = try? NSRegularExpression(
            pattern: #"auto-detected language:\s*([a-z]{2,3})"#
        ) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        let codeRange = m.range(at: 1)
        guard codeRange.location != NSNotFound else { return nil }
        return ns.substring(with: codeRange)
    }

    // MARK: - isWhisperNativeAudio
    // Port of `_is_whisper_native(src: Path)` from `core/transcriber.py`.
    // Operates on the leading bytes of a file (first 16 bytes are enough).
    // Returns true for WAV (RIFF/WAVE), MP3 (ID3 tag or bare MPEG sync),
    // and FLAC (fLaC). Returns false for anything else (M4A, MP4, OGG, etc.).
    //
    // Note: the Python implementation reads from a Path; the Swift port accepts
    // a byte array so tests can pass crafted headers without real files.

    /// Sniffs leading bytes for audio formats whisper.cpp handles natively.
    ///
    /// Oracle-locked port of `_is_whisper_native(src: Path)` from `core/transcriber.py`.
    /// Accepts `headerBytes` — the first 16 bytes of the file (fewer is OK; < 4 returns false).
    ///
    /// Returns `true` for:
    /// - WAV:  `RIFF….WAVE`
    /// - MP3:  `ID3` tag header
    /// - MP3:  bare MPEG frame sync `0xFF 0xFB / 0xF3 / 0xF2`
    /// - FLAC: `fLaC`
    public static func isWhisperNativeAudio(headerBytes: [UInt8]) -> Bool {
        guard headerBytes.count >= 4 else { return false }
        // WAV: bytes[0..3] == "RIFF" and bytes[8..11] == "WAVE"
        if headerBytes[0] == 0x52 && headerBytes[1] == 0x49
            && headerBytes[2] == 0x46 && headerBytes[3] == 0x46 {
            // Need at least 12 bytes for the WAVE marker
            if headerBytes.count >= 12
                && headerBytes[8] == 0x57 && headerBytes[9] == 0x41
                && headerBytes[10] == 0x56 && headerBytes[11] == 0x45 {
                return true
            }
            return false
        }
        // MP3 with ID3 tag: bytes[0..2] == "ID3"
        if headerBytes[0] == 0x49 && headerBytes[1] == 0x44 && headerBytes[2] == 0x33 {
            return true
        }
        // Bare MPEG frame sync: bytes[0] == 0xFF, bytes[1] in {0xFB, 0xF3, 0xF2}
        if headerBytes[0] == 0xFF
            && (headerBytes[1] == 0xFB || headerBytes[1] == 0xF3 || headerBytes[1] == 0xF2) {
            return true
        }
        // FLAC: bytes[0..3] == "fLaC"
        if headerBytes[0] == 0x66 && headerBytes[1] == 0x4C
            && headerBytes[2] == 0x61 && headerBytes[3] == 0x43 {
            return true
        }
        return false
    }

    // MARK: - whisperTimeoutSeconds
    // Port of `_whisper_timeout(mp3_path: Path)` from `core/transcriber.py`.
    // Formula: max(1800, int(mb * 90) + 120)
    // where mb = file_size_bytes / (1024 * 1024).
    // The "OSError fallback" in Python (non-existent file → floor) is covered
    // by the caller passing 0 or a sentinel; the Swift port takes fileSizeBytes
    // directly so no I/O is needed.

    /// Computes a per-episode whisper-cli timeout from the file size in bytes.
    ///
    /// Oracle-locked port of `_whisper_timeout(mp3_path)` from `core/transcriber.py`.
    /// Formula: `max(1800, Int(fileSizeBytes / 1_048_576.0 * 90) + 120)`.
    /// Floor of 1800 s guarantees at least 30 min for any file.
    public static func whisperTimeoutSeconds(fileSizeBytes: Int) -> Int {
        let mb = Double(fileSizeBytes) / 1_048_576.0   // 1024 * 1024
        return max(1800, Int(mb * 90) + 120)
    }

    // MARK: - frontmatter
    // Port of `_fmt_frontmatter(meta, engine, detected_language)` from
    // `core/transcriber.py`. The volatile `transcribed_at` field (which Python
    // derives from `datetime.now(timezone.utc).isoformat()`) is injected via
    // the `transcribedAt` parameter so this function is fully deterministic when
    // called with a fixed string. The default `""` signals "use current UTC time".
    //
    // Key order (fixed by Python code):
    //   guid, show_slug, title, pub_date, mp3_url,
    //   transcribed_at,
    //   detected_language (optional),
    //   whisper_version / whisper_model / model_sha256 (from engine, optional)
    //
    // All values are double-quoted. Output ends with "---\n\n".

    /// Renders YAML frontmatter for a whisper-transcribed episode `.md`.
    ///
    /// Oracle-locked port of `_fmt_frontmatter(meta, engine, detected_language)`
    /// from `core/transcriber.py`.
    ///
    /// - Parameters:
    ///   - meta: dict-like with keys `guid`, `show_slug`, `title`, `pub_date`, `mp3_url`.
    ///   - engine: optional dict with keys `whisper_version`, `whisper_model`,
    ///             `model_sha256` (keys with empty/nil values are silently dropped).
    ///   - detectedLanguage: ISO 639 code from whisper auto-detect, or `nil`.
    ///   - transcribedAt: the `transcribed_at` timestamp string to embed.
    ///                    Pass `""` (default) to use the current UTC time in
    ///                    Python's `datetime.now(timezone.utc).isoformat()` format.
    ///   - extra: **v2-only, additive** Obsidian-enrichment key/value pairs
    ///            (ordered), appended *after* every oracle-locked key and
    ///            *before* the closing `---`. This is a deliberate, intentional
    ///            divergence from the v1 `_fmt_frontmatter` byte-for-byte port —
    ///            v1 is frozen and never gets these fields. Values are emitted
    ///            double-quoted like the rest of this function's keys. Passing
    ///            no `extra` (the default) reproduces the original oracle-locked
    ///            output exactly, so existing callers/tests are unaffected.
    public static func frontmatter(
        meta: [String: String],
        engine: [String: String]? = nil,
        detectedLanguage: String? = nil,
        transcribedAt: String = "",
        extra: [(String, String)] = []
    ) -> String {
        var lines = ["---"]
        for key in ["guid", "show_slug", "title", "pub_date", "mp3_url"] {
            let v = meta[key] ?? ""
            lines.append("\(key): \"\(v)\"")
        }
        let ts: String
        if transcribedAt.isEmpty {
            // Live path: mirror Python's datetime.now(timezone.utc).isoformat()
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            ts = fmt.string(from: Date())
        } else {
            ts = transcribedAt
        }
        lines.append("transcribed_at: \"\(ts)\"")
        if let lang = detectedLanguage, !lang.isEmpty {
            lines.append("detected_language: \"\(lang)\"")
        }
        if let eng = engine {
            for key in ["whisper_version", "whisper_model", "model_sha256"] {
                if let v = eng[key], !v.isEmpty {
                    lines.append("\(key): \"\(v)\"")
                }
            }
        }
        // v2 Obsidian enrichment (additive-only; see `extra` doc above).
        for (key, value) in extra {
            lines.append("\(key): \"\(value)\"")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - banner
    // Port of `_banner(pub_date_str)` from `core/transcriber.py`
    // and `_age_banner(pub_date_str)` from `core/export.py`.
    // They are byte-identical. Both use `date.today()` internally.
    // The Swift port injects `now: Date` (default `Date()`) so tests can pin.
    //
    // Output format:
    //   > [!info] Episode vom YYYY-MM-DD (vor N Tagen)\n
    //   [> [!warning] ⚠ Stale: Folge ist älter als 1 Jahr(e) — zeitkritische Aussagen prüfen.\n]
    //   \n
    // Returns "" when the date can't be parsed.
    //
    // Stale threshold: age_days > 365 (Python: 365 * STALE_YEARS, STALE_YEARS=1).

    /// Returns the standard Obsidian callout banner for an episode.
    ///
    /// Oracle-locked port of `_banner(pub_date_str)` / `_age_banner(pub_date_str)`
    /// from `core/transcriber.py` and `core/export.py` (byte-identical implementations).
    ///
    /// - Parameters:
    ///   - pubDate: ISO date string (YYYY-MM-DD or longer; only first 10 chars used).
    ///   - now: reference date for age calculation. Default `Date()` matches Python's
    ///          `date.today()`. Inject a fixed value in tests.
    public static func banner(pubDate: String, now: Date = Date()) -> String {
        guard pubDate.count >= 10 else { return "" }
        let dateStr = String(pubDate.prefix(10))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let d = fmt.date(from: dateStr) else { return "" }

        // Compute today's date (date only, no time component) matching Python's date.today()
        let cal = Calendar(identifier: .gregorian)
        let todayComponents = cal.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: now
        )
        guard let todayDate = cal.date(from: DateComponents(
            year: todayComponents.year,
            month: todayComponents.month,
            day: todayComponents.day
        )) else { return "" }

        // Age in days: (date.today() - d).days in Python (integer division via timedelta)
        let ageDays = cal.dateComponents([.day], from: d, to: todayDate).day ?? 0

        var out = "> [!info] Episode vom \(dateStr) (vor \(ageDays) Tagen)\n"
        // Stale: age_days > 365 * 1 (STALE_YEARS = 1)
        if ageDays > 365 {
            out += "> [!warning] ⚠ Stale: Folge ist älter als 1 Jahr(e) — zeitkritische Aussagen prüfen.\n"
        }
        out += "\n"
        return out
    }

    // MARK: - srtToPlainText
    // Port of `_srt_to_plain_text(srt_text)` from `core/export.py`.
    // Strips SRT cue numbers (integer-only lines) and timestamp lines ("-->" present).
    // Strips leading/trailing whitespace from each line (Python: `raw.strip()`).
    // Skips blank lines. Joins remaining lines with "\n".

    /// Strips SRT cue numbers and timestamps, returning concatenated dialogue.
    ///
    /// Oracle-locked port of `_srt_to_plain_text(srt_text)` from `core/export.py`.
    public static func srtToPlainText(_ srtText: String) -> String {
        var out: [String] = []
        for raw in srtText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .init(charactersIn: " \t\r"))
            if line.isEmpty { continue }
            // Python: line.isdigit() — true iff ALL characters are ASCII digits
            if !line.isEmpty && line.allSatisfy({ $0.isASCII && $0.isNumber }) { continue }
            if line.contains("-->") { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - txtFromMarkdown
    // Extracted from the (formerly private, formerly untested) CLI helper
    // `LibraryCommands.synthesizeTxt(fromMarkdown:)` in
    // `Sources/vocateca-cli/Commands/Library.swift` — `library export --format txt`
    // has no standalone `.txt` sidecar on disk; it is always synthesized from the
    // `.md` transcript by stripping YAML frontmatter and markdown heading/quote
    // lines. Moved here so it's testable without `@testable import`-ing an
    // executable target, and so the UI's plain-text rendering (LibraryView) and
    // the CLI share one implementation instead of two independently-maintained
    // copies.

    /// Synthesizes plain text from a `.md` transcript by dropping the leading
    /// YAML frontmatter block (`---\n...\n---`) and any markdown heading (`#`)
    /// or blockquote (`>`) lines, joining what remains with `\n` and a
    /// trailing newline.
    ///
    /// Blank lines are dropped entirely (not preserved as paragraph breaks) —
    /// matches the CLI/UI's existing "one line per non-empty line" plain-text
    /// convention (see ``renderEpisodeHTML(title:showSlug:pubDate:body:)``,
    /// which does the same for its `<p>` splitting).
    public static func txtFromMarkdown(_ markdown: String) -> String {
        var body = markdown
        if body.hasPrefix("---") {
            let parts = body.components(separatedBy: "\n---")
            if parts.count >= 2 { body = parts.dropFirst().joined(separator: "\n---") }
        }
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(">") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - HTML export

    /// Escape the five XML/HTML special characters.
    public static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Render a self-contained, styled HTML page for a transcript. `body` is the
    /// plain transcript text (one paragraph per non-empty line).
    public static func renderEpisodeHTML(
        title: String,
        showSlug: String,
        pubDate: String,
        body: String
    ) -> String {
        let paragraphs = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { "  <p>\(htmlEscape(String($0)))</p>" }
            .joined(separator: "\n")
        let meta = [showSlug, pubDate].filter { !$0.isEmpty }.map(htmlEscape).joined(separator: " · ")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>\(htmlEscape(title))</title>
          <style>
            body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                   max-width: 720px; margin: 2.5rem auto; padding: 0 1.25rem; color: #1a1a1f; }
            @media (prefers-color-scheme: dark) { body { background: #16161a; color: #e8e8ea; } }
            h1 { font-size: 1.5rem; line-height: 1.25; margin: 0 0 .25rem; }
            .meta { color: #8a8a92; font-size: .85rem; margin: 0 0 1.75rem; }
            p { margin: 0 0 .9rem; }
          </style>
        </head>
        <body>
          <h1>\(htmlEscape(title))</h1>
          <p class="meta">\(meta)</p>
        \(paragraphs)
        </body>
        </html>
        """
    }

    // MARK: - srtToSegments / captionResult (YouTube captions → TranscriptionResult)

    /// Parses SRT text into timed segments (best-effort; malformed blocks skipped).
    public static func srtToSegments(_ srt: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        let normalised = srt.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .init(charactersIn: " \t\r")) }
                .filter { !$0.isEmpty }
            guard let tsIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[tsIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseSRTTimestamp(parts[0]),
                  let end = parseSRTTimestamp(parts[1]) else { continue }
            let text = stripCaptionTags(lines[(tsIdx + 1)...].joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptionSegment(start: start, end: end, text: text))
        }
        return segments
    }

    /// Parses `"HH:MM:SS,mmm"` (or `.` separator) into seconds; nil on failure.
    ///
    /// Tolerates trailing WebVTT cue settings on the timestamp line
    /// (`00:00:02,470 align:start position:0%`): the oracle-locked `vttToSRT`
    /// only strips settings introduced by a DOUBLE space, but YouTube separates
    /// them with a single space, so they survive into the SRT. We take the first
    /// whitespace-delimited token, which is always the bare timestamp.
    private static func parseSRTTimestamp(_ raw: String) -> Double? {
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? ""
        let s = token.replacingOccurrences(of: ",", with: ".")
        let hms = s.split(separator: ":")
        guard hms.count == 3,
              let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Removes WebVTT inline timing/formatting tags (`<00:00:01.319>`, `<c>…</c>`).
    static func stripCaptionTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    /// Collapses YouTube's rolling auto-caption duplication: consecutive identical
    /// lines and word-by-word build-ups (a line that is a prefix of the next).
    static func dedupeCaptionText(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for line in lines {
            if let last = out.last {
                if last == line { continue }                 // exact duplicate
                if line.hasPrefix(last) { out[out.count - 1] = line; continue }  // build-up → keep fuller
                if last.hasPrefix(line) { continue }         // shorter build-up after fuller
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Segment-level analogue of ``dedupeCaptionText``: collapses YouTube's
    /// rolling auto-caption duplication on timed segments. When a segment's
    /// (trimmed) text is a verbatim prefix of the next — or an exact duplicate —
    /// the two merge into one survivor carrying the fuller text and the group's
    /// widest timing (`start = min`, `end = max`). Order is otherwise preserved.
    /// Exact-string prefix match, mirroring ``dedupeCaptionText`` (no
    /// word-boundary logic). Intended for auto-generated captions only.
    static func dedupeCaptionSegments(_ segs: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var out: [TranscriptionSegment] = []
        for seg in segs {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = out.last {
                let lastText = last.text
                let merged = { (survivorText: String) in
                    TranscriptionSegment(
                        start: Swift.min(last.start, seg.start),
                        end: Swift.max(last.end, seg.end),
                        text: survivorText)
                }
                if lastText == text {                 // exact duplicate
                    out[out.count - 1] = merged(lastText); continue
                }
                if text.hasPrefix(lastText) {         // build-up → keep fuller (current)
                    out[out.count - 1] = merged(text); continue
                }
                if lastText.hasPrefix(text) {         // shorter build-up after fuller
                    out[out.count - 1] = merged(lastText); continue
                }
            }
            out.append(TranscriptionSegment(start: seg.start, end: seg.end, text: text))
        }
        return out
    }

    /// Builds a `TranscriptionResult` from a YouTube caption VTT, or nil if the
    /// captions are empty. Reuses the oracle-locked vtt→srt→text path, then strips
    /// inline caption tags and collapses rolling-caption duplication.
    /// When `isAuto` is true, dedup is applied to the timed segments and the text
    /// is rebuilt from them so the two stay consistent.
    public static func captionResult(fromVTT vtt: String, language: String?, isAuto: Bool = false) -> TranscriptionResult? {
        let srt = vttToSRT(vtt)
        if isAuto {
            let segments = dedupeCaptionSegments(srtToSegments(srt))
            let text = segments.map(\.text).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptionResult(text: text, segments: segments, language: language)
        }
        let text = dedupeCaptionText(stripCaptionTags(srtToPlainText(srt)))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptionResult(text: text, segments: srtToSegments(srt), language: language)
    }

    // MARK: - v2-additive export formats (VTT / CSV)
    //
    // NOT oracle-locked — there is no Python reference implementation for
    // either of these two formats. No golden fixtures; correctness is defined
    // by `TranscriptFormatCSVVTTTests` alone. Safe to evolve without
    // regenerating any fixture (unlike everything else in this file).

    /// Renders a standard WebVTT file from timed segments.
    ///
    /// v2-additive, NOT oracle-locked (see section doc above). Cue timestamps
    /// use the WebVTT `HH:MM:SS.mmm` convention (dot millisecond separator,
    /// unlike SRT's comma). No cue identifiers or cue settings are emitted —
    /// just the `WEBVTT` header, a blank line, then `start --> end` / text /
    /// blank-line cues in segment order. Empty input renders the bare header.
    public static func vttFromSegments(_ segments: [TranscriptionSegment]) -> String {
        let cues = segments.map { seg in
            "\(formatVTTTime(seg.start)) --> \(formatVTTTime(seg.end))\n\(seg.text)\n"
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n")
    }

    /// Formats seconds as WebVTT's `HH:MM:SS.mmm` (dot millisecond separator).
    /// Reuses the SRT formatter (`HH:MM:SS,mmm`) and swaps the separator, so
    /// the two formats' rounding/carry behaviour stays identical by construction.
    private static func formatVTTTime(_ seconds: Double) -> String {
        WhisperKitTranscriptionEngine.formatSRTTime(seconds).replacingOccurrences(of: ",", with: ".")
    }

    /// Renders segments as RFC-4180 CSV with header `start,end,speaker,text`.
    ///
    /// v2-additive, NOT oracle-locked (see section doc above).
    /// - `start`/`end`: seconds, 2 decimal places (`%.2f`).
    /// - `speaker`: `nil` -> empty field; a diarization index `n` -> `"S\(n + 1)"`
    ///   (1-based, matching `MarkdownLibraryWriter.speakerLabel`'s "Sprecher N"
    ///   convention in the short `SN` form CSV consumers expect).
    /// - `text` (and, defensively, every other field): RFC-4180 quoted when it
    ///   contains a comma, double quote, or newline — inner `"` doubled.
    public static func csvFromSegments(_ segments: [TranscriptionSegment]) -> String {
        var lines = ["start,end,speaker,text"]
        for seg in segments {
            let start = String(format: "%.2f", seg.start)
            let end = String(format: "%.2f", seg.end)
            let speaker = seg.speaker.map { "S\($0 + 1)" } ?? ""
            let row = [csvField(start), csvField(end), csvField(speaker), csvField(seg.text)]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC-4180 field quoting: wraps in `"…"` (doubling inner `"`) only when
    /// the field contains a comma, double quote, `\n`, or `\r`; otherwise
    /// returned unchanged.
    private static func csvField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else {
            return field
        }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - vttToSRT
    // Port of `vtt_to_srt(vtt)` from `core/youtube_captions.py`.
    //
    // Algorithm (matches Python exactly):
    // 1. Split into lines.
    // 2. Find first empty line → body = lines after it.
    //    If no empty line: body = all lines (Python ValueError path).
    // 3. Collect non-empty line runs into blocks (blank lines are delimiters).
    // 4. For each block:
    //    a. Find the first line containing "-->" (ts_idx).
    //       If none: skip block.
    //    b. ts_line = block[ts_idx], strip cue settings by taking everything
    //       before the FIRST double-space ("  ") occurrence.
    //       (Python: ts_line.split("  ")[0])
    //    c. Replace HH:MM:SS.mmm timestamps with HH:MM:SS,mmm using regex
    //       r"(\d{2}:\d{2}:\d{2})\.(\d{3})" → r"\1,\2".
    //    d. text_lines = block[ts_idx+1:]. If empty: skip.
    //    e. Increment counter n, emit: n / ts_line / text_lines... / "".
    // 5. Join with "\n" (note: final block ends with empty string → trailing \n).

    /// Converts WebVTT text to SRT format.
    ///
    /// Oracle-locked port of `vtt_to_srt(vtt)` from `core/youtube_captions.py`.
    /// Drops the WEBVTT header, cue identifiers, and cue settings.
    /// Replaces `.` millisecond separator with `,` in timestamps.
    public static func vttToSRT(_ vtt: String) -> String {
        let lines = vtt.components(separatedBy: "\n")

        // Find body: lines after first blank line; if no blank line, use all lines
        let body: [String]
        if let firstBlank = lines.firstIndex(where: { $0 == "" }) {
            body = Array(lines[(firstBlank + 1)...])
        } else {
            body = lines
        }

        // Collect non-empty runs into blocks
        var blocks: [[String]] = []
        var cur: [String] = []
        for line in body {
            if line.trimmingCharacters(in: .init(charactersIn: " \t\r")) == "" {
                if !cur.isEmpty {
                    blocks.append(cur)
                    cur = []
                }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { blocks.append(cur) }

        // NSRegularExpression to replace HH:MM:SS.mmm with HH:MM:SS,mmm
        // Pattern: r"(\d{2}:\d{2}:\d{2})\.(\d{3})"
        guard let tsRe = try? NSRegularExpression(
            pattern: #"(\d{2}:\d{2}:\d{2})\.(\d{3})"#
        ) else { return "" }

        var out: [String] = []
        var n = 0

        for blk in blocks {
            // Find index of timestamp line (first line containing "-->")
            guard let tsIdx = blk.firstIndex(where: { $0.contains("-->") }) else { continue }

            // Strip cue settings: take everything before first "  " (double space)
            var tsLine = blk[tsIdx]
            tsLine = tsLine.components(separatedBy: "  ").first ?? tsLine

            // Replace dot millisecond separator with comma
            let nsTs = tsLine as NSString
            let tsRange = NSRange(location: 0, length: nsTs.length)
            tsLine = tsRe.stringByReplacingMatches(
                in: tsLine,
                range: tsRange,
                withTemplate: "$1,$2"
            )

            let textLines = Array(blk[(tsIdx + 1)...])
            if textLines.isEmpty { continue }

            n += 1
            out.append(String(n))
            out.append(tsLine)
            out.append(contentsOf: textLines)
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    // MARK: - renderEpisodeMarkdown
    // Port of `render_episode_markdown(...)` from `core/export.py`.
    //
    // Frontmatter (no double-quotes on values, unlike _fmt_frontmatter):
    //   show_slug: <value>
    //   title: <value>
    //   source: <value>
    //   [youtube fields if source=="youtube"]
    // Body:
    //   [Watch link + blank line if youtube + youtube_id]
    //   [banner.rstrip("\n") if banner non-empty]
    //   srt_to_plain_text(srt_text)
    // Full output: "\n".join(fm) + "\n\n" + "\n".join(body_parts) + "\n"

    /// Renders an episode `.md` (frontmatter + body) for the given source.
    ///
    /// Oracle-locked port of `render_episode_markdown(...)` from `core/export.py`.
    ///
    /// - Parameters:
    ///   - showSlug: show identifier.
    ///   - title: episode title.
    ///   - srtText: SRT transcript text.
    ///   - source: `"youtube"` or `"podcast"`.
    ///   - youtubeID: YouTube video ID (for `source == "youtube"`).
    ///   - channelID: YouTube channel ID (for `source == "youtube"`).
    ///   - transcriptSource: caption source label (for `source == "youtube"`).
    ///   - pubDate: ISO date string for the age banner.
    ///   - now: reference date for age calculation; default `Date()` matches `date.today()`.
    ///   - extra: **v2-only, additive** Obsidian-enrichment key/value pairs
    ///            (ordered), appended after `source`/YouTube fields and before
    ///            the closing `---`. Unquoted, matching this function's existing
    ///            style. Passing no `extra` (the default) reproduces the
    ///            original oracle-locked output exactly.
    public static func renderEpisodeMarkdown(
        showSlug: String,
        title: String,
        srtText: String,
        source: String = "podcast",
        youtubeID: String? = nil,
        channelID: String? = nil,
        transcriptSource: String? = nil,
        pubDate: String = "",
        now: Date = Date(),
        extra: [(String, String)] = []
    ) -> String {
        var fm: [String] = ["---"]
        fm.append("show_slug: \(showSlug)")
        fm.append("title: \(title)")
        fm.append("source: \(source)")
        if source == "youtube" {
            if let ytID = youtubeID, !ytID.isEmpty {
                fm.append("youtube_id: \(ytID)")
                fm.append("youtube_url: https://youtu.be/\(ytID)")
            }
            if let chID = channelID, !chID.isEmpty {
                fm.append("channel_id: \(chID)")
            }
            if let ts = transcriptSource, !ts.isEmpty {
                fm.append("transcript_source: \(ts)")
            }
        }
        // v2 Obsidian enrichment (additive-only; see `extra` doc above).
        for (key, value) in extra {
            fm.append("\(key): \(value)")
        }
        fm.append("---")

        var bodyParts: [String] = []
        if source == "youtube", let ytID = youtubeID, !ytID.isEmpty {
            bodyParts.append("[Watch on YouTube](https://youtu.be/\(ytID))")
            bodyParts.append("")
        }
        let b = banner(pubDate: pubDate, now: now)
        if !b.isEmpty {
            // Python: body_parts.append(banner.rstrip("\n"))
            bodyParts.append(b.rstripNewlines())
        }
        bodyParts.append(srtToPlainText(srtText))

        return fm.joined(separator: "\n") + "\n\n" + bodyParts.joined(separator: "\n") + "\n"
    }
}

// MARK: - Private helpers

private extension String {
    /// Strips trailing newline characters, replicating Python's `str.rstrip('\n')`.
    func rstripNewlines() -> String {
        var s = self
        while s.last == "\n" { s.removeLast() }
        return s
    }
}
