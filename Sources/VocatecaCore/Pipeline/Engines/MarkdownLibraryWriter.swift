import Foundation

// MARK: - MarkdownLibraryWriter

/// A real `LibraryWriter` that persists transcript markdown (and optional SRT)
/// to the library directory.
///
/// ## Output paths
/// - **Podcast / YouTube**: `<outputRoot>/<showSlug>/<slug>.md`
///   and optionally `<showSlug>/<slug>.srt`.
/// - **Instagram image post**: `<outputRoot>/<igProfile>/<igShortcode>.md`
///   (body = `## Caption\n<caption>\n\n## OCR\n<ocrText>`).
///   Images are stored under `<outputRoot>/<igProfile>/<igShortcode>/NN.jpg` by the
///   caller; the writer places a reference section in the markdown.
///
/// All writes are atomic: data is written to a `.part` temp file then moved
/// into place with `FileManager.replaceItemAt(_:withItemAt:)`.
///
/// ## SRT sidecar
/// Pass `writeSRT: true` at initialisation to also write `<slug>.srt` next to the
/// `.md` file. Defaults to `true`.
///
/// ## OKF sidecar
/// Pass `writeOKF: true` at initialisation to also write `<slug>.okf.md` — an
/// Open Knowledge Format transcript (Markdown + YAML frontmatter) — next to the
/// `.md` file. Defaults to `false`.
public struct MarkdownLibraryWriter: LibraryWriter {

    // MARK: - Configuration

    /// Root directory for all library output.
    public let outputRoot: URL

    /// When `true`, writes a `.srt` file alongside the `.md` for podcast/YouTube episodes.
    public let writeSRT: Bool

    /// When `true`, writes a plain-text `.txt` sidecar alongside the `.md`.
    public let writeTXT: Bool

    /// When `true`, writes a styled, self-contained `.html` sidecar alongside the `.md`.
    public let writeHTML: Bool

    /// When `true`, writes an Open Knowledge Format `.okf.md` sidecar alongside the
    /// `.md` — a Markdown file with a small, minimally-opinionated YAML frontmatter
    /// block, per https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf.
    public let writeOKF: Bool

    /// When `true`, writes a WebVTT `.vtt` sidecar (subtitle cues, dot-millisecond
    /// timestamps) alongside the `.md`, built from `transcript.segments` via
    /// `TranscriptFormat.vttFromSegments`. v2-additive; defaults to `false`.
    public let writeVTT: Bool

    /// When `true`, writes an RFC-4180 CSV `.csv` sidecar (`start,end,speaker,text`)
    /// alongside the `.md`, built from `transcript.segments` via
    /// `TranscriptFormat.csvFromSegments`. v2-additive; defaults to `false`.
    public let writeCSV: Bool

    /// Extra Knowledge-Hub / export destination roots the `.md` is mirrored into
    /// (best-effort). Built from `KnowledgeHub.exportRoots(...)`. Empty = disabled.
    public let exportRoots: [URL]

    // MARK: - Init

    public init(
        outputRoot: URL,
        writeSRT: Bool = true,
        writeTXT: Bool = false,
        writeHTML: Bool = false,
        writeOKF: Bool = false,
        writeVTT: Bool = false,
        writeCSV: Bool = false,
        exportRoots: [URL] = []
    ) {
        self.outputRoot = outputRoot
        self.writeSRT = writeSRT
        self.writeTXT = writeTXT
        self.writeHTML = writeHTML
        self.writeOKF = writeOKF
        self.writeVTT = writeVTT
        self.writeCSV = writeCSV
        self.exportRoots = exportRoots
    }

    // MARK: - LibraryWriter

    public func write(
        episode: Episode,
        transcript: TranscriptionResult?,
        ocrText: String?,
        mediaPath: URL?
    ) async throws -> URL {

        // Route: Instagram image post vs audio transcript.
        if Pipeline.isImagePost(episode) {
            return try writeInstagramPost(episode: episode, ocrText: ocrText)
        } else {
            return try writePodcastTranscript(episode: episode, transcript: transcript)
        }
    }

    // MARK: - Podcast / YouTube transcript

    private func writePodcastTranscript(
        episode: Episode,
        transcript: TranscriptionResult?
    ) throws -> URL {
        let slug = Self.makeSlug(episode)
        // Slugify the show segment so a poisoned show_slug can't traverse the path.
        let showDir = outputRoot.appendingPathComponent(
            TextNormalization.slugify(episode.showSlug), isDirectory: true
        )
        try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)

        let mdURL      = showDir.appendingPathComponent("\(slug).md")
        let srtURL     = showDir.appendingPathComponent("\(slug).srt")
        let speakerURL = showDir.appendingPathComponent("\(slug).speakers.json")

        // Speaker diarization (Package D): whether any segment carries a speaker.
        // Drives the `.md` headers, the `.srt` `[SN]` prefixes, and the sidecar.
        // When false, every branch below is inert ⇒ byte-identical to before.
        let segments = transcript?.segments ?? []
        let hasSpeakers = segments.contains { $0.speaker != nil }

        // Build SRT text from segments if we have a transcript.
        // `srtText`        — un-prefixed; drives the plain-text `.md` body.
        // `srtSidecarText` — same, but with `[SN] ` caption prefixes for the `.srt`.
        let srtText: String
        let srtSidecarText: String
        if let t = transcript, !t.segments.isEmpty {
            srtText = WhisperKitTranscriptionEngine.buildSRT(segments: t.segments)
            srtSidecarText = hasSpeakers
                ? Self.buildSRTWithSpeakers(segments: t.segments)
                : srtText
        } else if let t = transcript {
            // No segments — wrap the full text as a single pseudo-segment.
            srtText = "1\n00:00:00,000 --> 00:00:01,000\n\(t.text)\n\n"
            srtSidecarText = srtText
        } else {
            srtText = ""
            srtSidecarText = ""
        }

        // Determine source (youtube vs podcast) from mp3Url.
        let source = URLSessionDownloader.isYouTubeURL(URL(string: episode.mp3Url) ?? URL(fileURLWithPath: "/")) ?
            "youtube" : "podcast"

        // v2 Obsidian-enrichment frontmatter fields, built from the Episode.
        // Additive-only: only emitted when the underlying datum exists/non-empty.
        // See TranscriptFormat.frontmatter/renderEpisodeMarkdown `extra:` doc.
        let enrichment = Self.obsidianEnrichment(episode: episode, includeSourceURL: source == "youtube")
        // Obsidian wikilink to the show note, rendered into the banner area.
        let showWikilink = "> [[\(episode.showSlug)]]\n\n"

        // The plain-text transcript body both paths derive from srtText, plus its
        // speaker-annotated variant (identical to `plainBody` when hasSpeakers==false).
        let plainBody = TranscriptFormat.srtToPlainText(srtText)
        let annotatedBody = Self.annotateBodyWithSpeakers(plainBody: plainBody, segments: segments)

        // Build markdown.
        let markdownContent: String
        if source == "youtube" {
            let fm = TranscriptFormat.renderEpisodeMarkdown(
                showSlug: episode.showSlug,
                title: episode.title,
                srtText: srtText,
                source: "youtube",
                pubDate: episode.pubDate,
                extra: enrichment
            )
            // renderEpisodeMarkdown ends with the transcript body ("…\(plainBody)\n").
            // When speakers are present, swap that trailing body region for the
            // header-annotated one — the oracle-locked builder itself is untouched,
            // and when hasSpeakers==false annotatedBody == plainBody ⇒ no-op.
            let withSpeakers: String
            if hasSpeakers, let r = fm.range(of: plainBody + "\n", options: .backwards) {
                withSpeakers = fm.replacingCharacters(in: r, with: annotatedBody + "\n")
            } else {
                withSpeakers = fm
            }
            // Splice the wikilink in right after the frontmatter, before the body.
            markdownContent = Self.insertAfterFrontmatter(withSpeakers, insert: showWikilink)
        } else {
            // Podcast: whisper-style frontmatter + banner + plain (or annotated) body.
            let fm = TranscriptFormat.frontmatter(
                meta: [
                    "guid":      episode.guid,
                    "show_slug": episode.showSlug,
                    "title":     episode.title,
                    "pub_date":  episode.pubDate,
                    "mp3_url":   episode.mp3Url,
                ],
                detectedLanguage: episode.detectedLanguage,
                extra: enrichment
            )
            let bannerStr = TranscriptFormat.banner(pubDate: episode.pubDate)
            markdownContent = fm + showWikilink + bannerStr + annotatedBody + "\n"
        }

        // Atomic write.
        try atomicWrite(content: markdownContent, to: mdURL)

        // Write SRT sidecar (with `[SN]` caption prefixes when speakers are present).
        if writeSRT && !srtSidecarText.isEmpty {
            try atomicWrite(content: srtSidecarText, to: srtURL)
        }

        // Write the speaker sidecar `<slug>.speakers.json` — ONLY when at least one
        // segment carries a speaker. Zero-based indices, matching the segments.
        if let entries = Self.speakerSidecar(segments: segments) {
            let data = try Self.encodeSpeakerSidecar(entries)
            let json = String(decoding: data, as: UTF8.self)
            try atomicWrite(content: json, to: speakerURL)
            Log.debug("Diarization: wrote speakers sidecar",
                      component: "Library",
                      context: [("dest", speakerURL.path), ("segments", String(entries.count))])
        }

        // Optional plain-text / HTML sidecars (transcription path only).
        if (writeTXT || writeHTML), let t = transcript {
            let plainFromSrt = TranscriptFormat.srtToPlainText(srtText)
            let plain = plainFromSrt.isEmpty ? t.text : plainFromSrt
            if writeTXT {
                let txtURL = showDir.appendingPathComponent("\(slug).txt")
                try atomicWrite(content: plain + "\n", to: txtURL)
            }
            if writeHTML {
                let htmlURL = showDir.appendingPathComponent("\(slug).html")
                let html = TranscriptFormat.renderEpisodeHTML(
                    title: episode.title,
                    showSlug: episode.showSlug,
                    pubDate: episode.pubDate,
                    body: plain
                )
                try atomicWrite(content: html, to: htmlURL)
            }
        }

        // Optional WebVTT sidecar (transcription path only). Built directly
        // from `transcript.segments` — no independent transcription state,
        // matching the writeTXT/writeHTML/writeOKF sidecars above/below.
        if writeVTT, let t = transcript {
            let vttURL = showDir.appendingPathComponent("\(slug).vtt")
            let vtt = TranscriptFormat.vttFromSegments(t.segments)
            try atomicWrite(content: vtt, to: vttURL)
            Log.debug("Library: wrote .vtt sidecar", component: "Library",
                      context: [("dest", vttURL.path), ("segments", String(t.segments.count))])
        }

        // Optional CSV sidecar (transcription path only). Built directly from
        // `transcript.segments`, which already carry diarization speaker
        // indices when available — the CSV `speaker` column is only ever
        // non-empty HERE, at auto-save time. The on-demand Library export
        // path (Task A.5) has no independent transcription state and instead
        // synthesizes segments from the `.srt` sidecar, which carries no
        // speaker info — a documented, accepted caveat (see design doc).
        if writeCSV, let t = transcript {
            let csvURL = showDir.appendingPathComponent("\(slug).csv")
            let csv = TranscriptFormat.csvFromSegments(t.segments)
            try atomicWrite(content: csv, to: csvURL)
            Log.debug("Library: wrote .csv sidecar", component: "Library",
                      context: [("dest", csvURL.path), ("segments", String(t.segments.count))])
        }

        // Optional Open Knowledge Format sidecar (transcription path only). Uses
        // the extension `.okf.md` (not `.okf`) so it never collides with the
        // plain library `.md`. Reuses the same segments/timestamps/speaker data
        // as the primary `.md` — no independent transcription state.
        if writeOKF, let t = transcript {
            let okfURL = showDir.appendingPathComponent("\(slug).okf.md")
            let okfContent = Self.renderOKF(
                episode: episode,
                source: source,
                segments: segments,
                hasSpeakers: hasSpeakers,
                fallbackText: t.text
            )
            try atomicWrite(content: okfContent, to: okfURL)
        }

        // Mirror to the configured Knowledge-Hub / export roots (best-effort).
        mirrorToExportRoots(content: markdownContent,
                            showSegment: TextNormalization.slugify(episode.showSlug),
                            filename: "\(slug).md")

        return mdURL
    }

    // MARK: - Instagram image post

    private func writeInstagramPost(
        episode: Episode,
        ocrText: String?
    ) throws -> URL {
        // Determine directory: <outputRoot>/<igProfile>/ or <showSlug>/.
        // igProfile/igShortcode originate from gallery-dl metadata controlled by
        // the (followed) post owner, so an unsanitized value like "../../etc"
        // would otherwise traverse out of outputRoot. Use safePathSegment (NOT
        // slugify) so the case-significant base-62 shortcode keeps its identity.
        let profileKey = TextNormalization.safePathSegment(episode.igProfile ?? episode.showSlug)
        let shortcode  = TextNormalization.safePathSegment(episode.igShortcode ?? Self.makeSlug(episode))

        let profileDir = outputRoot.appendingPathComponent(profileKey, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let mdURL = profileDir.appendingPathComponent("\(shortcode).md")

        // Build IG post markdown.
        var parts: [String] = []

        // Frontmatter.
        parts.append("---")
        parts.append("ig_profile: \(profileKey)")
        parts.append("ig_shortcode: \(shortcode)")
        if let kind = episode.igKind { parts.append("ig_kind: \(kind)") }
        parts.append("title: \(episode.title)")
        parts.append("pub_date: \(episode.pubDate)")
        parts.append("show_slug: \(episode.showSlug)")
        parts.append("---")
        parts.append("")

        // Caption section.
        let caption = episode.description ?? ""
        parts.append("## Caption")
        parts.append("")
        if caption.isEmpty {
            parts.append("_(no caption)_")
        } else {
            parts.append(caption)
        }
        parts.append("")

        // OCR section.
        parts.append("## OCR")
        parts.append("")
        if let ocr = ocrText, !ocr.isEmpty {
            parts.append(ocr)
        } else {
            parts.append("_(no OCR text)_")
        }
        parts.append("")

        let markdownContent = parts.joined(separator: "\n")
        try atomicWrite(content: markdownContent, to: mdURL)

        mirrorToExportRoots(content: markdownContent,
                            showSegment: profileKey,
                            filename: "\(shortcode).md")

        return mdURL
    }

    // MARK: - Knowledge-Hub / export mirroring

    /// Writes `content` to `<root>/<showSegment>/<filename>` for every configured
    /// export root. Best-effort: a failing destination is logged and skipped — it
    /// must never fail the transcript itself.
    private func mirrorToExportRoots(content: String, showSegment: String, filename: String) {
        guard !exportRoots.isEmpty else { return }
        for root in exportRoots {
            let dir = root.appendingPathComponent(showSegment, isDirectory: true)
            let dest = dir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try atomicWrite(content: content, to: dest)
                Log.debug("Knowledge-Hub: exported transcript",
                          component: "Export", context: [("dest", dest.path)])
            } catch {
                Log.warn("Knowledge-Hub: export failed (skipped)",
                         component: "Export",
                         context: [("dest", dest.path), ("error", "\(error)")])
            }
        }
    }

    // MARK: - Atomic write helper

    private func atomicWrite(content: String, to destination: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw PipelineError.permanent("Failed to encode content as UTF-8")
        }
        let tmpURL = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).part")
        do {
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: destination)
            }
        } catch let pe as PipelineError {
            throw pe
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw PipelineError.transient("Disk write failed: \(error)")
        }
    }

    // MARK: - Obsidian enrichment (v2-only, additive)

    /// Builds the ordered `extra` key/value pairs passed to
    /// `TranscriptFormat.frontmatter` / `renderEpisodeMarkdown` for Obsidian
    /// enrichment. Every field is emitted **only when its source datum exists
    /// and is non-empty** — this keeps the frontmatter minimal for episodes
    /// with partial metadata and matches the byte-for-byte-safe "additive"
    /// contract those two builders guarantee for callers that omit `extra`.
    ///
    /// - `transcript_origin`: engine-agnostic provenance string
    ///   (`asr:<engine>:<model>` / `captions:auto` / `ocr`), see `TranscriptOrigin`.
    /// - `duration_sec` / `word_count`: numeric episode metadata, stringified.
    /// - `source_url`: only for the non-podcast (`renderEpisodeMarkdown`) path,
    ///   where `mp3_url` isn't already an oracle-locked frontmatter key.
    static func obsidianEnrichment(episode: Episode, includeSourceURL: Bool) -> [(String, String)] {
        var extra: [(String, String)] = []
        if let origin = episode.transcriptOrigin, !origin.isEmpty {
            extra.append(("transcript_origin", origin))
        }
        if let duration = episode.durationSec {
            extra.append(("duration_sec", String(duration)))
        }
        if let words = episode.wordCount {
            extra.append(("word_count", String(words)))
        }
        if includeSourceURL, !episode.mp3Url.isEmpty {
            extra.append(("source_url", episode.mp3Url))
        }
        return extra
    }

    /// Splices `insert` into a rendered frontmatter+body string right after the
    /// closing `---\n\n` of the frontmatter block, before the existing body.
    /// Used to add the Obsidian show wikilink to `renderEpisodeMarkdown`'s output
    /// without touching that oracle-locked function itself.
    static func insertAfterFrontmatter(_ rendered: String, insert: String) -> String {
        guard let range = rendered.range(of: "---\n\n") else { return insert + rendered }
        // Find the SECOND occurrence of "---\n\n" is not needed: renderEpisodeMarkdown
        // always emits exactly one "---\n\n" separator (frontmatter close + blank line)
        // before the body, since frontmatter lines never contain that literal sequence.
        var result = rendered
        result.insert(contentsOf: insert, at: range.upperBound)
        return result
    }

    // MARK: - Speaker diarization (Package D — persistence D1)

    /// One entry of the `<slug>.speakers.json` sidecar. `speaker` is **zero-based**,
    /// matching `TranscriptionSegment.speaker` (the 1-based "Sprecher N" label is a
    /// display concern applied in the `.md`/`.srt` and the Library UI).
    struct SpeakerSidecarEntry: Codable, Equatable {
        let start: Double
        let end: Double
        let speaker: Int
    }

    /// Builds the sidecar payload from every segment that carries a speaker, in
    /// segment order. Returns `nil` when no segment has a speaker (⇒ no sidecar).
    static func speakerSidecar(segments: [TranscriptionSegment]) -> [SpeakerSidecarEntry]? {
        let entries = segments.compactMap { seg -> SpeakerSidecarEntry? in
            guard let spk = seg.speaker else { return nil }
            return SpeakerSidecarEntry(start: seg.start, end: seg.end, speaker: spk)
        }
        return entries.isEmpty ? nil : entries
    }

    /// Encodes the sidecar as a compact, key-ordered JSON array
    /// (`[{"start":…,"end":…,"speaker":…}]`).
    static func encodeSpeakerSidecar(_ entries: [SpeakerSidecarEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entries)
    }

    /// 1-based display label for a zero-based speaker index. Persisted literally in
    /// the `.md`/`.srt` as "Sprecher N"; the Library UI localises the display copy.
    static func speakerLabel(_ zeroBased: Int) -> String { "Sprecher \(zeroBased + 1)" }

    /// Builds an SRT string whose every caption text line is prefixed with `[SN] `
    /// (1-based) when that segment carries a `speaker`; segments with `speaker == nil`
    /// are left exactly as `WhisperKitTranscriptionEngine.buildSRT` would emit them.
    ///
    /// A caption's text may itself contain newlines — every non-first line of the
    /// caption is prefixed too, so the tag is unambiguous per displayed line.
    static func buildSRTWithSpeakers(segments: [TranscriptionSegment]) -> String {
        var parts: [String] = []
        for (index, seg) in segments.enumerated() {
            parts.append(String(index + 1))
            parts.append("\(WhisperKitTranscriptionEngine.formatSRTTime(seg.start)) --> "
                         + "\(WhisperKitTranscriptionEngine.formatSRTTime(seg.end))")
            if let spk = seg.speaker {
                let tag = "[S\(spk + 1)] "
                let tagged = seg.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { tag + $0 }
                    .joined(separator: "\n")
                parts.append(tagged)
            } else {
                parts.append(seg.text)
            }
            parts.append("")   // blank line separator
        }
        return parts.joined(separator: "\n")
    }

    /// Annotates a plain-text transcript body (as produced by
    /// `TranscriptFormat.srtToPlainText`) with bold `**Sprecher N**` headers,
    /// inserted before the block of each segment whose speaker differs from the
    /// previously-labelled one.
    ///
    /// - When NO segment has a speaker, returns `plainBody` **unchanged** — this is
    ///   what preserves byte-for-byte parity with the pre-diarization writer.
    /// - The body's non-transcript lines (banner, YouTube watch-link) are not part
    ///   of `plainBody` here (callers pass only the `srtToPlainText` output), so
    ///   this only ever interleaves headers between dialogue lines.
    ///
    /// Line accounting mirrors `srtToPlainText`: each segment contributes its
    /// `text` split on `\n` with blank/whitespace-only lines dropped. Segments that
    /// contribute zero visible lines (empty text) still advance the speaker state
    /// so a following same-speaker block doesn't get a spurious header.
    static func annotateBodyWithSpeakers(
        plainBody: String,
        segments: [TranscriptionSegment]
    ) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return plainBody }

        var out: [String] = []
        var lastLabelled: Int? = nil
        for seg in segments {
            // The visible lines this segment contributes to srtToPlainText output.
            let visible = seg.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .init(charactersIn: " \t\r")) }
                .filter { !$0.isEmpty }

            if let spk = seg.speaker, spk != lastLabelled {
                if !out.isEmpty { out.append("") }        // blank line before a new block
                out.append("**\(speakerLabel(spk))**")
                out.append("")
                lastLabelled = spk
            }
            out.append(contentsOf: visible)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - OKF (Open Knowledge Format) export

    /// Renders an Open Knowledge Format transcript: a Markdown file with a
    /// small, minimally-opinionated YAML frontmatter block, per
    /// https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf.
    ///
    /// Reuses the same segment/timestamp/speaker data as the primary `.md`
    /// export — no independent transcription state. `speakers` is omitted
    /// entirely when `hasSpeakers` is false, and per-line speaker prefixes are
    /// dropped in the body too.
    ///
    /// Public so the Library UI can synthesize an OKF view on demand for
    /// episodes transcribed before save_okf was enabled (no sidecar on disk).
    public static func renderOKF(
        episode: Episode,
        source: String,
        segments: [TranscriptionSegment],
        hasSpeakers: Bool,
        fallbackText: String
    ) -> String {
        var fm: [String] = ["---"]
        fm.append("type: reference")
        fm.append("title: \(Self.yamlQuote(episode.title))")
        fm.append("resource: \(Self.yamlQuote(episode.mp3Url))")
        fm.append("source: \(Self.yamlQuote(source))")
        if hasSpeakers {
            let labels = Self.speakerLabelsOKF(segments: segments)
            if !labels.isEmpty {
                fm.append("speakers: [\(labels.map(Self.yamlQuote).joined(separator: ", "))]")
            }
        }
        let showTag = TextNormalization.slugify(episode.showSlug)
        // showTag is a slug (alphanumeric + `-`), always a safe unquoted YAML
        // flow scalar — matches the OKF spec's `tags: [transcript, <show-slug>]`.
        fm.append("tags: [transcript, \(showTag)]")
        let ts = episode.pubDate.isEmpty ? Self.isoNow() : episode.pubDate
        fm.append("timestamp: \(Self.yamlQuote(ts))")
        if let origin = episode.transcriptOrigin, !origin.isEmpty {
            fm.append("origin: \(Self.yamlQuote(origin))")
        }
        fm.append("---")
        let frontmatter = fm.joined(separator: "\n") + "\n\n"

        var body: [String] = []
        body.append("# \(episode.title)")
        body.append("")
        body.append("## Transcript")
        body.append("")
        if segments.isEmpty {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { body.append(text) }
        } else {
            for seg in segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let stamp = "**[\(Self.formatMMSS(seg.start))]**"
                if hasSpeakers, let spk = seg.speaker {
                    body.append("\(stamp) Speaker \(spk + 1): \(text)")
                } else {
                    body.append("\(stamp) \(text)")
                }
            }
        }
        return frontmatter + body.joined(separator: "\n") + "\n"
    }

    /// Ordered, de-duplicated "Speaker N" labels (1-based) present in `segments`,
    /// in order of first appearance.
    static func speakerLabelsOKF(segments: [TranscriptionSegment]) -> [String] {
        var seen = Set<Int>()
        var labels: [String] = []
        for seg in segments {
            guard let spk = seg.speaker, !seen.contains(spk) else { continue }
            seen.insert(spk)
            labels.append("Speaker \(spk + 1)")
        }
        return labels
    }

    /// Formats non-negative seconds as zero-padded `MM:SS` (minutes grow past
    /// two digits for long episodes rather than wrapping).
    static func formatMMSS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Current UTC time in ISO-8601 — the OKF `timestamp` fallback when the
    /// episode has no `pub_date`.
    static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    /// Double-quotes a YAML scalar, escaping embedded backslashes/quotes.
    static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Slug helper

    /// Makes a filesystem-safe slug from the episode guid (alphanumeric + `-_`).
    static func makeSlug(_ episode: Episode) -> String {
        let raw = episode.guid.lowercased()
        let safe = raw.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).contains($0) }
            .map(Character.init)
        return String(safe.prefix(80)).isEmpty ? episode.guid : String(safe.prefix(80))
    }
}
