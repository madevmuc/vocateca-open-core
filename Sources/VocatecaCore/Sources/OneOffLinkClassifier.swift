import Foundation

// MARK: - OneOffLinkKind

/// What a pasted one-off link resolves to. `generic` covers any http(s) link that
/// yt-dlp may handle (SoundCloud, Vimeo, …) plus unknowns.
public enum OneOffLinkKind: String, Equatable, Sendable {
    case youtube, instagram, podcast, spotify, generic

    /// YouTube/Instagram/Podcast links can offer "subscribe instead"; a generic
    /// link has nothing pollable behind it, so it goes straight to one-off.
    ///
    /// `spotify` is handled specially (Spotify audio is DRM-protected and can't be
    /// downloaded — the one-off sheet resolves the show name and routes into the
    /// podcast directory), so it does NOT use the generic transcribe/subscribe fork.
    public var offersSubscribe: Bool { self != .generic && self != .spotify }
}

// MARK: - OneOffLinkClassifier

/// Classifies a pasted one-off link into a ``OneOffLinkKind``.
///
/// Mirrors `AddSourceSheet.detectType`'s signal order, but treats YouTube
/// *videos* and *channels* both as `.youtube` — the one-off sheet handles the
/// subscribe-vs-transcribe-once fork itself.
public enum OneOffLinkClassifier {
    public static func classify(_ text: String) -> OneOffLinkKind {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .generic }
        // Spotify is DRM-protected (yt-dlp can't fetch it) — resolve to the show's
        // public feed via the podcast directory instead.
        if SpotifyURL.parse(t) != nil { return .spotify }
        // A bare `@handle` IS Instagram here, and deliberately so — this looks
        // like `AddSourceClassifier`'s old Instagram-first branch (which sent
        // every handle, YouTube's included, to Instagram) but the input differs.
        // This classifier only ever sees a LINK: it backs `transcribe <url>`, the
        // one-off sheet's paste field and CSV lines. There is no search to fall
        // through to, so the two outcomes for a handle are Instagram or
        // `.generic` — and `.generic` hands `@natgeo` to yt-dlp, which cannot do
        // anything with it. Instagram is the only place a bare handle is a usable
        // address; YouTube's own handles arrive here as `/@` channel URLs.
        if t.hasPrefix("@") || t.contains("instagram.com") { return .instagram }
        if t.contains("youtube.com") || t.contains("youtu.be") { return .youtube }
        if t.hasPrefix("http"), t.contains("rss") || t.contains(".xml") || t.contains("feed") {
            return .podcast
        }
        return .generic
    }
}
