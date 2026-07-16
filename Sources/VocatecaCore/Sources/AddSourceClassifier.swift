import Foundation

// MARK: - AddSourceKind

/// What a pasted string in the "Add" front door resolves to — the TOP-LEVEL
/// routing decision (podcast subscribe / search, YouTube subscribe, Instagram
/// subscribe, or a generic yt-dlp-handled URL that goes to the one-off path).
///
/// This is a pure, testable extraction of the decision logic that used to live
/// only inline as `AddSourceSheet.detectType(_:)` (a `VocatecaUI` view file).
/// `AddSourceSheet.detectType` and `AddRouterSheet`'s fast path both now
/// delegate here so the exact same signal order drives every entry point
/// ("per-tab Add" buttons + the intent-first router) without needing a UI
/// harness to verify routing.
public enum AddSourceKind: Equatable, Sendable {
    case none
    case podcast
    case youtube
    case instagram
    case podcastSearch
    /// A URL that yt-dlp recognises but isn't YouTube/podcast/Instagram
    /// (SoundCloud, Vimeo, Bandcamp, a single YouTube video, Spotify, …).
    case genericURL
}

// MARK: - AddSourceClassifier

/// Classifies a pasted "Add Source" link/search term into an ``AddSourceKind``.
///
/// Oracle-locked to the pre-extraction behaviour of
/// `AddSourceSheet.detectType(_:)` — do not reorder the branches without
/// re-checking `Tests/VocatecaCoreTests/Sources/AddSourceClassifierTests.swift`.
public enum AddSourceClassifier {

    /// Classify `text` (a raw paste from the Add field) into an ``AddSourceKind``.
    ///
    /// Signal order (first match wins):
    /// 1. Empty (after trimming whitespace) → `.none`.
    /// 2. An `instagram.com` URL → `.instagram`.
    /// 3. A `youtube.com`/`youtu.be`/`/@` URL:
    ///    - A single **video** URL (`youtu.be/ID`, `/watch?v=ID`) is a one-off
    ///      import, not a subscribe target → `.genericURL`.
    ///    - Everything else recognised as YouTube (channel/handle/playlist) → `.youtube`.
    /// 4. An `http(s)` URL containing `rss` / `.xml` / `feed` → `.podcast`.
    /// 5. Any other `http(s)` URL (SoundCloud, Vimeo, Bandcamp, Spotify, …) → `.genericURL`.
    /// 6. Anything else — including a bare `@handle` — is a search term → `.podcastSearch`.
    public static func classify(_ text: String) -> AddSourceKind {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .none }

        // Instagram signals — the URL only.
        //
        // A bare `@handle` used to land here, which was wrong: `@` is not an
        // Instagram marker. YouTube handles look identical — `@hubermanlab` is a
        // real YouTube channel with 7.5M subscribers AND a real Instagram account,
        // and nothing in the string says which the user meant. Because this branch
        // ran first, EVERY bare handle became Instagram and no `@handle` could ever
        // reach YouTube (which is only matched via `/@` — i.e. a full channel URL),
        // while the Add field's own placeholder advertised "YouTube @handle".
        //
        // Ambiguous input is a search, not a guess: a bare handle now falls through
        // to `.podcastSearch` and gets looked up. Instagram keeps the unambiguous
        // signal it always had — an instagram.com link.
        if t.contains("instagram.com") {
            return .instagram
        }
        // YouTube signals. A single VIDEO (youtu.be/ID, /watch?v=ID) is a one-off
        // import — route it to the generic yt-dlp path (download+transcribe once).
        // Only channels/handles/playlists use the YouTube subscribe path.
        if t.contains("youtube.com") || t.contains("youtu.be") || t.contains("/@") {
            if let parsed = try? YouTubeURL.parse(t), parsed.kind == .video {
                return .genericURL
            }
            return .youtube
        }
        // RSS / podcast URL signals
        if t.hasPrefix("http") && (t.contains("rss") || t.contains(".xml") || t.contains("feed")) {
            return .podcast
        }
        // Generic URL (SoundCloud, Vimeo, Bandcamp, Spotify, etc.) — yt-dlp may handle it.
        if t.hasPrefix("http") {
            return .genericURL
        }
        // Search term
        return .podcastSearch
    }
}
