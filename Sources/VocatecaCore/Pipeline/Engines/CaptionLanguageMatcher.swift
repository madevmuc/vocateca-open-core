import Foundation

// MARK: - CaptionLanguageMatcher

/// Pure caption-track selection: given a video's available ``CaptionTrack``s
/// and a language preference, picks the single best track.
///
/// Exists to fix a region-mismatch bug (P6/P6-EXT): requesting a video's own
/// `%(language)s` code verbatim against yt-dlp's `--sub-langs` can miss the
/// actual track id when the two disagree on region — e.g. metadata says
/// `"en-US"` but the auto-caption track is filed under `"en"`; metadata says
/// `"de"` but the manual track is filed under `"de-DE"`. Region fallback
/// below is BIDIRECTIONAL (desired's base vs. track's base, either
/// direction) so both cases resolve.
///
/// No I/O, no yt-dlp — standalone/testable so ``CaptionLanguageMatchTests``
/// can exercise it with a hand-built track list.
public enum CaptionLanguageMatcher {

    /// Selects the best track from `tracks`.
    ///
    /// Tier order:
    /// 1. Exact `languageCode` match against `desiredLanguage`.
    /// 2. Base-language prefix match against `desiredLanguage` (e.g.
    ///    `"en-US"` matches a track filed as `"en"`; `"de"` matches a track
    ///    filed as `"de-DE"`).
    /// 3. If `desiredLanguage` is `nil` (no explicit preference — the
    ///    default `captions(forVideoURL:)` path), the same exact/base match
    ///    is retried against `originalLanguage` (the video's own creator
    ///    language).
    /// 4. Unknown-language default (both 1–3 missed): the source ASR track
    ///    if tagged `<lang>-orig`, else an English/German track if present
    ///    (the app's supported UI locales), else the first manual track,
    ///    else the first track, else `nil` when `tracks` is empty. Never
    ///    picks a blind alphabetically-first machine auto-translation.
    ///
    /// Within tiers 1–3, a manual (`isAuto == false`) match is always
    /// preferred over an auto match in the same language.
    ///
    /// - Parameters:
    ///   - tracks: The video's available caption tracks (manual + auto),
    ///     e.g. from ``YtDlpCaptionFetcher/listTracks(videoURL:binaryManager:subprocess:timeout:)``.
    ///   - desiredLanguage: An explicit language request (e.g. a UI
    ///     language-picker selection), or `nil` for "use the default
    ///     selection order".
    ///   - originalLanguage: The video's own creator-authored language
    ///     (yt-dlp's `%(language)s`), or `nil` if unknown. Only consulted
    ///     when `desiredLanguage` is `nil`.
    public static func selectTrack(
        from tracks: [CaptionTrack],
        desiredLanguage: String?,
        originalLanguage: String?
    ) -> CaptionTrack? {
        if let found = match(query: desiredLanguage, in: tracks) {
            return found
        }
        if desiredLanguage == nil, let found = match(query: originalLanguage, in: tracks) {
            return found
        }
        // Both desired and original language are nil/unmatched — this is the
        // "unknown language" case (music/older/ASR-only uploads report
        // `%(language)s` as empty/"NA"). `automatic_captions` on such videos
        // lists the real ASR track PLUS 100+ machine auto-translations as
        // equal-looking keys, so falling straight to `tracks.first` used to
        // pick whatever auto-translation happened to sort first
        // alphabetically (e.g. "ab"/"af") — a silently wrong-language
        // transcript. Prefer, in order: the source ASR track (YouTube tags
        // it `<lang>-orig`), then a track in the app's supported UI
        // languages (English, then German), and only then fall back to
        // first-manual/first-track.
        if let origTrack = tracks.first(where: { $0.languageCode.lowercased().hasSuffix("-orig") }) {
            return origTrack
        }
        for preferred in ["en", "de"] {
            if let found = match(query: preferred, in: tracks) {
                return found
            }
        }
        if let manual = tracks.first(where: { !$0.isAuto }) {
            return manual
        }
        return tracks.first
    }

    // MARK: - Private helpers

    /// Exact-then-base match of `query` against `tracks`, manual preferred
    /// over auto within each tier. Returns `nil` if `query` is `nil`/empty or
    /// nothing matches.
    private static func match(query: String?, in tracks: [CaptionTrack]) -> CaptionTrack? {
        guard let query, !query.isEmpty else { return nil }

        let exact = tracks.filter { $0.languageCode.caseInsensitiveCompare(query) == .orderedSame }
        if let found = preferManual(among: exact) { return found }

        let queryBase = baseLanguage(query)
        let baseMatches = tracks.filter { baseLanguage($0.languageCode) == queryBase }
        if let found = preferManual(among: baseMatches) { return found }

        return nil
    }

    /// The manual candidate if there is one, else the first candidate, else
    /// `nil` when `candidates` is empty.
    private static func preferManual(among candidates: [CaptionTrack]) -> CaptionTrack? {
        candidates.first(where: { !$0.isAuto }) ?? candidates.first
    }

    /// The base-language portion of a BCP-47-ish code: `"en-US"` -> `"en"`,
    /// `"de"` -> `"de"`. Lowercased so comparisons are case-insensitive.
    private static func baseLanguage(_ code: String) -> String {
        let base = code.split(separator: "-", maxSplits: 1).first.map(String.init) ?? code
        return base.lowercased()
    }
}
