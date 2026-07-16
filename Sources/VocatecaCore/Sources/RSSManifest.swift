import Foundation
import FeedKit

// MARK: - ManifestEntry

/// One episode entry in the RSS/Atom manifest.
///
/// Field names and coding keys match the Python oracle exactly so the JSON
/// produced by this type is byte-compatible with the golden fixtures.
public struct ManifestEntry: Codable, Sendable, Equatable {

    // MARK: Stored properties (snake_case naming mirrors Python dict keys)

    /// Unique episode identifier. For podcast RSS this is the `<guid>` value;
    /// for YouTube channel-atom feeds it is the bare 11-char video ID.
    public let guid: String

    /// Episode title (empty string when absent in the feed).
    public let title: String

    /// Publication date as "YYYY-MM-DDTHH:MM:SS" (UTC, no timezone suffix).
    /// Empty string when the feed carries no date for the entry.
    public let pubDate: String

    /// Raw `<itunes:duration>` text as it appears in the XML (e.g. "1699" or
    /// "00:28:19"). Falls back to "00:00:00" when the element is absent.
    public let duration: String

    /// Four-digit zero-padded episode number from `<itunes:episode>` (e.g.
    /// "0042"). "0000" when absent or unparseable.
    public let episodeNumber: String

    /// Audio URL: for podcast RSS feeds the enclosure `href`; for YouTube
    /// atom entries a synthesised `https://www.youtube.com/watch?v=<id>`.
    public let mp3URL: String

    /// Episode description / show notes (plain text or HTML). Empty string when
    /// absent.
    public let description: String

    /// Episode landing-page URL (the `<link>` element). Empty string when absent.
    public let url: String

    // MARK: CodingKeys

    /// JSON keys must match the Python golden output exactly.
    enum CodingKeys: String, CodingKey {
        case guid            = "guid"
        case title           = "title"
        case pubDate         = "pubDate"
        case duration        = "duration"
        case episodeNumber   = "episode_number"
        case mp3URL          = "mp3_url"
        case description     = "description"
        case url             = "url"
    }
}

// MARK: - RSSManifest

/// Oracle-locked port of `core/rss.py::build_manifest_with_url`.
///
/// Parses podcast RSS 2.0 feeds and YouTube channel Atom feeds from raw XML
/// bytes and returns a sorted `[ManifestEntry]` that is **byte-for-byte
/// identical** to the Python reference for all inputs in the golden fixture
/// `Tests/VocatecaCoreTests/Fixtures/oracle/rss_manifest.json`.
///
/// Do NOT change the mapping logic without regenerating the goldens and
/// running `swift test --filter OracleRSSTests`.
public enum RSSManifest {

    // MARK: - Public API

    /// Parse raw XML bytes (RSS 2.0 or Atom) and return the canonical sorted
    /// manifest list.
    ///
    /// - Parameter data: Raw feed bytes (UTF-8 XML).
    /// - Returns: Manifest entries, oldest-first by `pubDate` string.
    /// - Throws: `RSSManifestError` on parse failure.
    public static func build(fromXML data: Data) throws -> [ManifestEntry] {
        // 1. Lightweight custom-XML pass: capture raw fields FeedKit doesn't preserve
        let raw = RSSRawExtractor.extract(from: data)

        // 2. FeedKit structural parse
        let parser = FeedParser(data: data)
        let result = parser.parse()

        switch result {
        case .success(let feed):
            switch feed {
            case .rss(let rssFeed):
                return try buildFromRSS(rssFeed, raw: raw)
            case .atom(let atomFeed):
                return try buildFromAtom(atomFeed, raw: raw)
            case .json:
                throw RSSManifestError.unsupportedFeedType
            }
        case .failure(let error):
            throw RSSManifestError.parseError(error)
        }
    }

    /// Parse the feed-level author / owner from raw XML bytes (RSS 2.0 or Atom).
    ///
    /// Priority order (RSS 2.0):
    ///   1. `<itunes:author>` (feed channel level, outside any `<item>`)
    ///   2. `<itunes:owner><itunes:name>`
    ///   3. `<managingEditor>`
    ///
    /// Returns an empty string when no author is found or on parse failure.
    /// Does NOT throw — caller silently treats empty as "unknown".
    public static func parseFeedAuthor(fromXML data: Data) -> String {
        let extractor = FeedAuthorXMLParser(data: data)
        return extractor.parse()
    }

    /// Parse the channel-level title from raw XML bytes (RSS 2.0 or Atom).
    ///
    /// Returns the `<title>` element at the channel/feed level (outside any
    /// `<item>` or `<entry>`). For Atom feeds this is the top-level `<title>`.
    ///
    /// Returns an empty string when no title is found or on parse failure.
    /// Does NOT throw — caller silently treats empty as "unknown".
    public static func parseFeedTitle(fromXML data: Data) -> String {
        let extractor = FeedTitleXMLParser(data: data)
        return extractor.parse()
    }

    /// Parse the channel-level artwork URL from raw XML bytes (RSS 2.0 or Atom).
    ///
    /// Priority order:
    ///   1. `<itunes:image href="…">` at the channel level (outside any `<item>`)
    ///   2. `<image><url>…</url></image>` (RSS 2.0 channel image)
    ///   3. `<logo>…</logo>` (Atom feed)
    ///   4. `<icon>…</icon>` (Atom feed fallback)
    ///
    /// Returns an empty string when no artwork is found or on parse failure.
    /// Does NOT throw — caller silently treats empty as "no artwork".
    public static func parseFeedArtwork(fromXML data: Data) -> String {
        let extractor = FeedArtworkXMLParser(data: data)
        return extractor.parse()
    }

    /// Parse the channel-level description / summary from raw XML bytes.
    ///
    /// Priority order (RSS 2.0 / Atom):
    ///   1. `<itunes:summary>` at the channel/feed level (outside any `<item>`)
    ///   2. `<description>` (RSS 2.0 channel)
    ///   3. `<subtitle>` (Atom feed)
    ///
    /// Handles CDATA-wrapped content (descriptions commonly use it). Returns an
    /// empty string when no description is found or on parse failure. Does NOT
    /// throw — caller silently treats empty as "no description".
    ///
    /// Because the channel description sits before the `<item>`s, this parses
    /// correctly even from a byte-capped head of the feed. If the head is
    /// truncated *mid-`<description>`* (the closing tag never arrives), the text
    /// captured so far is still returned rather than discarded.
    public static func parseFeedDescription(fromXML data: Data) -> String {
        let extractor = FeedChannelMetaXMLParser(data: data)
        return extractor.parse().description
    }

    /// Parse the channel/feed-level `<language>` tag from raw XML bytes.
    ///
    /// Returns the raw BCP-47 / RFC-1766 code as it appears in the feed
    /// (e.g. `"de-DE"`, `"en-us"`), lower-preserved. Empty string when absent or
    /// on parse failure. The `<language>` element sits at the channel level
    /// before the `<item>`s, so this parses correctly from a byte-capped head.
    public static func parseFeedLanguage(fromXML data: Data) -> String {
        let extractor = FeedChannelMetaXMLParser(data: data)
        return extractor.parse().language
    }

    /// Channel-level metadata parsed from a single feed-head pass: the podcast
    /// title, description/summary, declared `<language>` code, and artwork URL.
    ///
    /// `title` and `artworkURL` were added so the refresh-metadata path
    /// (``FeedIngestor/poll(show:store:)``) can recover a show's real title and
    /// artwork from the SAME already-fetched feed bytes used for episode
    /// parsing — no second network fetch. Empty string means "not found in this
    /// feed"; callers must treat empty as "leave existing value untouched",
    /// never as "blank it out".
    public struct ChannelMeta: Sendable, Equatable {
        public let title: String
        public let description: String
        public let language: String
        public let artworkURL: String
        public init(title: String = "", description: String, language: String, artworkURL: String = "") {
            self.title = title
            self.description = description
            self.language = language
            self.artworkURL = artworkURL
        }
    }

    /// Parse the channel title, description, `<language>`, and artwork URL in
    /// one XML pass — used by the podcast-search preview (description/language)
    /// and by the refresh-metadata path (title/artwork), so a single feed fetch
    /// yields everything needed. Truncation-tolerant (see
    /// ``parseFeedDescription(fromXML:)``).
    public static func parseFeedChannelMeta(fromXML data: Data) -> ChannelMeta {
        let extractor = FeedChannelMetaXMLParser(data: data)
        return extractor.parse()
    }

    /// Map a feed `<language>` code (e.g. `"de-DE"`, `"en"`) to a display name
    /// localised for the *current* UI locale (a German user sees "Deutsch",
    /// "Englisch"; an English user sees "German", "English"). Falls back to the
    /// raw code when it can't be mapped, and returns `nil` for an empty code.
    public static func languageDisplayName(
        for code: String,
        locale: Locale = .current
    ) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Take the primary subtag before any region/script suffix ("de-DE" → "de").
        let primary = Show.primaryLanguageSubtag(trimmed)
        if let name = locale.localizedString(forLanguageCode: primary),
           !name.isEmpty {
            // Capitalise the first letter for locales (like German) that lower-case
            // language names mid-sentence; standalone it should read as a proper noun.
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed
    }
}

// MARK: - Errors

public enum RSSManifestError: Error {
    case parseError(Error)
    case unsupportedFeedType
}

// MARK: - RSS 2.0 builder

private extension RSSManifest {

    static func buildFromRSS(
        _ feed: RSSFeed,
        raw: RSSRawExtractor.Result
    ) throws -> [ManifestEntry] {
        var entries: [ManifestEntry] = []

        for (idx, item) in (feed.items ?? []).enumerated() {
            let rawEntry = raw.entries(at: idx)

            // mp3 extraction: mirrors _extract_mp3_url
            // feedparser checks links first (type=="audio/mpeg" or rel=="enclosure"),
            // then falls back to enclosures (type starts with "audio" or is empty).
            // FeedKit maps RSS enclosures to item.enclosure.
            let mp3 = extractMP3fromRSSItem(item)

            guard let mp3URL = mp3, !mp3URL.isEmpty else {
                // YouTube-in-RSS is not a real case for our feeds, but follow the pattern:
                // entries with no mp3 AND no youtube id are skipped.
                continue
            }

            let guidValue = item.guid?.value ?? mp3URL

            entries.append(ManifestEntry(
                guid: guidValue,
                title: item.title ?? "",
                pubDate: pubDateISO(item.pubDate),
                duration: rawEntry?.duration ?? "00:00:00",
                episodeNumber: episodeNumber(item.iTunes?.iTunesEpisode),
                mp3URL: mp3URL,
                description: (item.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                url: item.link ?? ""
            ))
        }

        entries.sort { $0.pubDate < $1.pubDate }
        return entries
    }

    /// Extract the audio/mpeg URL from an RSS item.
    ///
    /// Mirrors `_extract_mp3_url` from `core/rss.py`:
    /// 1. Prefer an enclosure with type "audio/mpeg"
    /// 2. Fallback: enclosure whose type starts with "audio" or is empty
    static func extractMP3fromRSSItem(_ item: RSSFeedItem) -> String? {
        // FeedKit exposes a single <enclosure> element.
        if let enc = item.enclosure, let attrs = enc.attributes, let url = attrs.url {
            let t = attrs.type ?? ""
            if t == "audio/mpeg" || t.hasPrefix("audio") || t.isEmpty {
                return url
            }
        }
        return nil
    }
}

// MARK: - Atom builder

private extension RSSManifest {

    static func buildFromAtom(
        _ feed: AtomFeed,
        raw: RSSRawExtractor.Result
    ) throws -> [ManifestEntry] {
        var entries: [ManifestEntry] = []

        for (idx, entry) in (feed.entries ?? []).enumerated() {
            let rawEntry = raw.entries(at: idx)

            // mp3 extraction for Atom (podcast Atom would have enclosure links).
            // YouTube Atom entries have no enclosure — synthesise from yt:videoId.
            let mp3: String
            var guidValue: String

            if let audioURL = extractMP3fromAtomEntry(entry) {
                // Normal podcast Atom with audio enclosure
                mp3 = audioURL
                guidValue = entry.id ?? audioURL
            } else {
                // Try YouTube: extract videoId from raw yt:videoId or from entry.id
                let vid = rawEntry?.ytVideoId ?? youtubeVideoIDFromEntryID(entry.id)
                guard let videoID = vid, !videoID.isEmpty else {
                    // No mp3 and no youtube id -> skip
                    continue
                }
                mp3 = "https://www.youtube.com/watch?v=\(videoID)"
                guidValue = videoID
            }

            // Description: for YouTube Atom, feedparser maps media:group/media:description
            // to entry.summary. FeedKit doesn't expose this path, so we use raw extractor.
            // feedparser strips leading/trailing whitespace on summaries (verified for
            // both RSS <description> and Atom media:description), so we trim here too to
            // stay byte-exact with the oracle and consistent with the RSS path above.
            let rawDescriptionValue: String
            if let summaryValue = entry.summary?.value, !summaryValue.isEmpty {
                rawDescriptionValue = summaryValue
            } else if let rawDesc = rawEntry?.mediaGroupDescription, !rawDesc.isEmpty {
                rawDescriptionValue = rawDesc
            } else {
                rawDescriptionValue = ""
            }
            let descriptionValue = rawDescriptionValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // Alternate link (the episode landing page)
            let urlValue = alternateLink(from: entry.links) ?? ""

            entries.append(ManifestEntry(
                guid: guidValue,
                title: entry.title ?? "",
                pubDate: pubDateISO(entry.published ?? entry.updated),
                duration: rawEntry?.duration ?? "00:00:00",
                episodeNumber: "0000",  // Atom feeds don't have itunes:episode
                mp3URL: mp3,
                description: descriptionValue,
                url: urlValue
            ))
        }

        entries.sort { $0.pubDate < $1.pubDate }
        return entries
    }

    /// Extract audio URL from Atom entry links (rel="enclosure" with audio type).
    static func extractMP3fromAtomEntry(_ entry: AtomFeedEntry) -> String? {
        for link in entry.links ?? [] {
            guard let attrs = link.attributes, let href = attrs.href else { continue }
            let type_ = attrs.type ?? ""
            let rel = attrs.rel ?? ""
            if type_ == "audio/mpeg" || rel == "enclosure" {
                if !href.isEmpty { return href }
            }
        }
        for link in entry.links ?? [] {
            guard let attrs = link.attributes, let href = attrs.href else { continue }
            let type_ = attrs.type ?? ""
            if type_.hasPrefix("audio") || type_.isEmpty {
                // only take if rel is enclosure or there's no other signal
                let rel = attrs.rel ?? ""
                if rel == "enclosure" { return href }
            }
        }
        return nil
    }

    /// Extract the alternate link href from an Atom entry's link list.
    static func alternateLink(from links: [AtomFeedEntryLink]?) -> String? {
        guard let links = links else { return nil }
        // First try an explicit rel="alternate"
        if let alt = links.first(where: { $0.attributes?.rel == "alternate" }) {
            return alt.attributes?.href
        }
        // Fallback: first link without an enclosure rel
        return links.first(where: { ($0.attributes?.rel ?? "alternate") != "enclosure" })?.attributes?.href
    }

    /// Replicate `_youtube_video_id` fallback: extract from "yt:video:VIDEOID" entry id.
    static func youtubeVideoIDFromEntryID(_ id: String?) -> String? {
        guard let id = id else { return nil }
        let prefix = "yt:video:"
        if id.hasPrefix(prefix) {
            let vid = String(id.dropFirst(prefix.count))
            return vid.isEmpty ? nil : vid
        }
        return nil
    }
}

// MARK: - Date formatting

private extension RSSManifest {

    /// Format a `Date` as "YYYY-MM-DDTHH:MM:SS" in UTC.
    ///
    /// Mirrors `_pub_date_iso` in `core/rss.py`:
    ///   `datetime(*published_parsed[:6]).isoformat()`
    /// feedparser normalises ALL timezones to UTC before exposing
    /// `published_parsed`, so the components are UTC.  FeedKit likewise
    /// stores its `Date` values in UTC (the parsed RFC-822 / RFC-3339 date
    /// is converted to an absolute `Date`).  We therefore format using the
    /// UTC calendar to reproduce the same YYYY-MM-DDTHH:MM:SS string.
    static func pubDateISO(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return utcFormatter.string(from: date)
    }

    static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

// MARK: - Episode number

private extension RSSManifest {

    /// Replicate `_episode_number` from `core/rss.py`.
    ///
    /// `str(int(itunes_episode)).zfill(4)` → "0042"; "0000" when absent or
    /// unparseable.
    static func episodeNumber(_ value: Int?) -> String {
        guard let n = value else { return "0000" }
        return String(format: "%04d", n)
    }
}

// MARK: - RSSRawExtractor

/// Lightweight `XMLParser` pass over raw feed bytes to capture fields that
/// FeedKit does not expose:
///
/// - `<itunes:duration>` text (raw, preserved verbatim — feedparser returns
///   the original string, whereas FeedKit converts to `TimeInterval`).
/// - `<yt:videoId>` text (YouTube namespace, not handled by FeedKit).
/// - `<media:group><media:description>` text (Atom YouTube entries —
///   feedparser maps this to `entry.summary`; FeedKit's `AtomPath` has no
///   mapping for this path).
///
/// Entries are keyed by their parse order (0-based index) to align with the
/// FeedKit entries array.
enum RSSRawExtractor {

    // MARK: Per-entry raw metadata

    struct EntryMeta {
        var duration: String?
        var ytVideoId: String?
        var mediaGroupDescription: String?
    }

    // MARK: Extraction result

    struct Result {
        private var perEntry: [Int: EntryMeta]

        init(_ dict: [Int: EntryMeta]) { self.perEntry = dict }

        func entries(at index: Int) -> EntryMeta? { perEntry[index] }
    }

    // MARK: - extract(from:)

    static func extract(from data: Data) -> Result {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Result(delegate.entries)
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, XMLParserDelegate {

        var entries: [Int: EntryMeta] = [:]

        // Track current element nesting
        private var entryIndex: Int = -1
        private var inEntry: Bool = false      // inside <item> or <entry>
        private var inMediaGroup: Bool = false  // inside <media:group>

        // Current element being collected
        private var currentElement: String?
        private var currentText: String = ""

        // MARK: XMLParserDelegate

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let local = localName(qName ?? elementName)

            switch local {
            case "item", "entry":
                entryIndex += 1
                inEntry = true
                inMediaGroup = false

            case "media:group", "mediaGroup" where inEntry:
                inMediaGroup = true

            default:
                break
            }

            // Decide whether to capture character data for this element.
            // We capture: itunes:duration, yt:videoId (= yt:videoid lower), media:description (in media:group)
            if inEntry {
                switch local {
                case "itunes:duration", "duration" where namespaceURI?.contains("itunes") == true:
                    startCapture(element: "itunes:duration")
                case "yt:videoId", "yt:videoid", "videoId", "videoid"
                    where namespaceURI?.contains("youtube") == true
                        || namespaceURI?.contains("yt") == true:
                    startCapture(element: "yt:videoId")
                case "media:description", "description"
                    where inMediaGroup
                        && (namespaceURI?.contains("media") == true
                            || namespaceURI?.contains("yahoo") == true):
                    startCapture(element: "media:description")
                default:
                    break
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            foundCharacters string: String
        ) {
            if currentElement != nil {
                currentText += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let local = localName(qName ?? elementName)

            // Close element: save if we were capturing
            if let cap = currentElement {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    switch cap {
                    case "itunes:duration":
                        entries[entryIndex, default: EntryMeta()].duration = text
                    case "yt:videoId":
                        entries[entryIndex, default: EntryMeta()].ytVideoId = text
                    case "media:description":
                        entries[entryIndex, default: EntryMeta()].mediaGroupDescription = text
                    default:
                        break
                    }
                }
                // Stop capturing
                switch local {
                case "itunes:duration", "duration",
                     "yt:videoId", "yt:videoid", "videoId", "videoid",
                     "media:description", "description":
                    endCapture()
                default:
                    break
                }
            }

            switch local {
            case "media:group", "mediaGroup":
                inMediaGroup = false
            case "item", "entry":
                inEntry = false
                inMediaGroup = false
            default:
                break
            }
        }

        // MARK: Helpers

        private func startCapture(element: String) {
            guard currentElement == nil else { return }  // already capturing
            currentElement = element
            currentText = ""
        }

        private func endCapture() {
            currentElement = nil
            currentText = ""
        }

        /// Strip namespace prefix from a qualified name so we can match on the
        /// local part, but KEEP the prefixed version for known namespaces.
        private func localName(_ qName: String) -> String {
            // Return the qualifiedName as-is — it already includes the prefix
            // (e.g. "itunes:duration", "yt:videoId") which lets us distinguish
            // <description> from <media:description>.
            return qName
        }
    }
}

// MARK: - FeedAuthorXMLParser

/// Lightweight `XMLParser` pass that extracts the feed-level author string from
/// an RSS 2.0 podcast feed (not from per-entry fields).
///
/// Priority (first non-empty wins):
///   1. `<itunes:author>` at the channel level (outside `<item>`)
///   2. `<itunes:name>` inside `<itunes:owner>` at the channel level
///   3. `<managingEditor>` at the channel level
private final class FeedAuthorXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let data: Data

    // Result candidates
    private var itunesAuthor = ""
    private var itunesOwnerName = ""
    private var managingEditor = ""

    // State tracking
    private var inItem = false         // inside <item> — ignore channel-level duplicates
    private var inItunesOwner = false
    private var currentElement: String?
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // Priority order
        let candidates = [itunesAuthor, itunesOwnerName, managingEditor]
        return candidates.first(where: { !$0.isEmpty }) ?? ""
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        switch name {
        case "item", "entry":
            inItem = true
        case "itunes:owner" where !inItem:
            inItunesOwner = true
        case "itunes:author" where !inItem,
             "itunes:name" where inItunesOwner && !inItem,
             "managingEditor" where !inItem:
            currentElement = name
            currentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if let cap = currentElement, name == cap {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch cap {
            case "itunes:author":   itunesAuthor = trimmed
            case "itunes:name":     itunesOwnerName = trimmed
            case "managingEditor":  managingEditor = trimmed
            default: break
            }
            currentElement = nil
            currentText = ""
        }
        switch name {
        case "item", "entry":    inItem = false
        case "itunes:owner":     inItunesOwner = false
        default: break
        }
    }
}

// MARK: - FeedTitleXMLParser

/// Lightweight `XMLParser` pass that extracts the feed-level title string from
/// an RSS 2.0 or Atom feed (not from per-entry/item fields).
///
/// For RSS 2.0: the `<title>` at the `<channel>` level (outside `<item>`).
/// For Atom: the `<title>` at the `<feed>` level (outside `<entry>`).
private final class FeedTitleXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let data: Data

    private var feedTitle = ""

    // State tracking
    private var inItem = false         // inside <item> or <entry>
    private var inFeedTitle = false    // capturing the channel/feed title
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return feedTitle
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        switch name {
        case "item", "entry":
            inItem = true
        case "title" where !inItem && feedTitle.isEmpty:
            // Only capture the first <title> at the channel/feed level.
            inFeedTitle = true
            currentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFeedTitle { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if inFeedTitle && name == "title" {
            feedTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            inFeedTitle = false
            currentText = ""
        }
        switch name {
        case "item", "entry": inItem = false
        default: break
        }
    }
}

// MARK: - FeedArtworkXMLParser

/// Lightweight `XMLParser` pass that extracts the feed-level artwork URL from
/// an RSS 2.0 or Atom feed.
///
/// Priority (first non-empty wins):
///   1. `<itunes:image href="…">` at the channel level (outside `<item>`)
///   2. `<image><url>…</url></image>` (RSS 2.0 channel image)
///   3. `<logo>…</logo>` (Atom)
///   4. `<icon>…</icon>` (Atom fallback)
private final class FeedArtworkXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let data: Data

    // Result candidates (filled in priority order)
    private var itunesImageHref = ""
    private var rssImageURL = ""
    private var atomLogo = ""
    private var atomIcon = ""

    // State tracking
    private var inItem = false          // inside <item> or <entry>
    private var inRSSImage = false      // inside <image> block (RSS 2.0 channel image)
    private var currentElement: String?
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // Return first non-empty in priority order
        let candidates = [itunesImageHref, rssImageURL, atomLogo, atomIcon]
        return candidates.first(where: { !$0.isEmpty }) ?? ""
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        switch name {
        case "item", "entry":
            inItem = true

        case "itunes:image" where !inItem:
            // itunes:image carries the URL in the `href` attribute.
            if itunesImageHref.isEmpty, let href = attributes["href"], !href.isEmpty {
                itunesImageHref = href
            }

        case "image" where !inItem:
            // RSS 2.0 <image> block — wait for inner <url>.
            inRSSImage = true

        case "url" where inRSSImage && !inItem:
            currentElement = "url"
            currentText = ""

        case "logo" where !inItem:
            currentElement = "logo"
            currentText = ""

        case "icon" where !inItem:
            currentElement = "icon"
            currentText = ""

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName

        if let cap = currentElement, name == cap {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch cap {
            case "url"  where inRSSImage: if rssImageURL.isEmpty { rssImageURL = trimmed }
            case "logo":                  if atomLogo.isEmpty     { atomLogo    = trimmed }
            case "icon":                  if atomIcon.isEmpty     { atomIcon    = trimmed }
            default: break
            }
            currentElement = nil
            currentText = ""
        }

        switch name {
        case "item", "entry": inItem = false; inRSSImage = false
        case "image":         inRSSImage = false
        default: break
        }
    }
}

// MARK: - FeedChannelMetaXMLParser

/// Lightweight `XMLParser` pass that extracts the channel/feed-level title,
/// description (or summary), declared `<language>`, and artwork URL from an
/// RSS 2.0 or Atom feed in a single pass (not from per-item fields).
///
/// Description priority: `<itunes:summary>` > `<description>` > `<subtitle>`,
/// each at the channel/feed level (outside `<item>`/`<entry>`). Captures both
/// plain and CDATA-wrapped text (podcast summaries almost always use CDATA).
/// Artwork priority mirrors ``FeedArtworkXMLParser``: `<itunes:image href>` >
/// RSS `<image><url>` > Atom `<logo>` > Atom `<icon>`.
///
/// **Truncation tolerance:** podcast-search fetches only a byte-capped *head* of
/// the feed. If that head cuts off mid-`<description>` — so `didEndElement`
/// never fires and `XMLParser` reports a `parseErrorOccurred` — the text
/// captured so far is still committed rather than lost, which is the whole
/// reason the preview description used to come back empty for long summaries.
private final class FeedChannelMetaXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let data: Data

    // Best match found so far, by descending priority. Once a higher-priority
    // element is captured we stop overwriting with lower-priority ones.
    private var summary: String = ""       // itunes:summary (priority 1)
    private var channelDesc: String = ""   // description    (priority 2)
    private var subtitle: String = ""      // subtitle       (priority 3)
    private var language: String = ""      // <language> code
    private var feedTitle: String = ""     // channel/feed-level <title>

    // Artwork candidates, filled in priority order (mirrors FeedArtworkXMLParser).
    private var itunesImageHref = ""
    private var rssImageURL = ""
    private var atomLogo = ""
    private var atomIcon = ""

    // State tracking
    private var inItem = false             // inside <item> or <entry>
    private var inFeedTitle = false        // capturing the channel/feed-level <title>
    private var inRSSImage = false         // inside <image> block (RSS 2.0 channel image)
    private var capturing: String? = nil   // which channel-level field we're in
    private var currentText = ""
    private var currentImageElement: String? = nil
    private var currentImageText = ""
    private var titleText = ""             // in-flight text for the channel/feed <title>

    init(data: Data) {
        self.data = data
    }

    func parse() -> RSSManifest.ChannelMeta {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        // If parsing stopped mid-capture (truncated head), flush whatever text we
        // had collected so a long description isn't discarded.
        flushPendingCapture()
        let description: String
        if !summary.isEmpty { description = summary }
        else if !channelDesc.isEmpty { description = channelDesc }
        else { description = subtitle }
        let artwork = [itunesImageHref, rssImageURL, atomLogo, atomIcon]
            .first(where: { !$0.isEmpty }) ?? ""
        return RSSManifest.ChannelMeta(
            title: feedTitle,
            description: description,
            language: language,
            artworkURL: artwork
        )
    }

    /// Commit the in-flight capture (used when the parser ends normally without
    /// a closing tag, e.g. truncated feed head).
    private func flushPendingCapture() {
        if let field = capturing {
            commit(field: field, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            capturing = nil
            currentText = ""
        }
        if inFeedTitle {
            feedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            inFeedTitle = false
            titleText = ""
        }
        if let cap = currentImageElement {
            commitImage(field: cap, text: currentImageText.trimmingCharacters(in: .whitespacesAndNewlines))
            currentImageElement = nil
            currentImageText = ""
        }
    }

    private func commit(field: String, text: String) {
        guard !text.isEmpty else { return }
        switch field {
        case "itunes:summary": if summary.isEmpty { summary = text }
        case "description":    if channelDesc.isEmpty { channelDesc = text }
        case "subtitle", "itunes:subtitle": if subtitle.isEmpty { subtitle = text }
        case "language":       if language.isEmpty { language = text }
        default: break
        }
    }

    /// Commit an in-flight `<image>`-block sub-element capture (`<url>`) — mirrors
    /// ``FeedArtworkXMLParser``'s priority scheme.
    private func commitImage(field: String, text: String) {
        guard !text.isEmpty else { return }
        switch field {
        case "url"  where inRSSImage: if rssImageURL.isEmpty { rssImageURL = text }
        case "logo":                  if atomLogo.isEmpty    { atomLogo    = text }
        case "icon":                  if atomIcon.isEmpty    { atomIcon    = text }
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        switch name {
        case "item", "entry":
            inItem = true

        case "title" where !inItem && feedTitle.isEmpty && !inRSSImage:
            // Only capture the first channel/feed-level <title>, and never the
            // one nested inside the RSS <image> block (that's the image's alt title).
            inFeedTitle = true
            titleText = ""

        case "itunes:summary" where !inItem && summary.isEmpty,
             "description"      where !inItem && channelDesc.isEmpty,
             "subtitle", "itunes:subtitle",
             "language"         where !inItem && language.isEmpty:
            // Capture the first channel-level occurrence of each field.
            guard !inItem else { break }
            capturing = name
            currentText = ""

        case "itunes:image" where !inItem:
            // itunes:image carries the URL in the `href` attribute — no text capture needed.
            if itunesImageHref.isEmpty, let href = attributes["href"], !href.isEmpty {
                itunesImageHref = href
            }

        case "image" where !inItem:
            // RSS 2.0 <image> block — wait for inner <url>.
            inRSSImage = true

        case "url" where inRSSImage && !inItem:
            currentImageElement = "url"
            currentImageText = ""

        case "logo" where !inItem:
            currentImageElement = "logo"
            currentImageText = ""

        case "icon" where !inItem:
            currentImageElement = "icon"
            currentImageText = ""

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { currentText += string }
        if inFeedTitle { titleText += string }
        if currentImageElement != nil { currentImageText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // Mirror `foundCharacters` exactly: a CDATA block can carry ANY captured
        // field's text, not just the description. Podcast hosts (e.g. Captivate)
        // routinely CDATA-wrap the channel `<title>` — `<title><![CDATA[…]]></title>`
        // — so handling only `capturing` here silently dropped the feed title
        // (leaving shows displaying their slug after reconnect / refresh, while
        // the artwork — an `href` attribute, not CDATA — came through fine).
        guard let s = String(data: CDATABlock, encoding: .utf8) else { return }
        if capturing != nil { currentText += s }
        if inFeedTitle { titleText += s }
        if currentImageElement != nil { currentImageText += s }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName

        if let field = capturing, field == name {
            commit(field: field, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            capturing = nil
            currentText = ""
        }

        if inFeedTitle && name == "title" {
            feedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            inFeedTitle = false
            titleText = ""
        }

        if let cap = currentImageElement, name == cap {
            commitImage(field: cap, text: currentImageText.trimmingCharacters(in: .whitespacesAndNewlines))
            currentImageElement = nil
            currentImageText = ""
        }

        switch name {
        case "item", "entry": inItem = false; inRSSImage = false
        case "image":         inRSSImage = false
        default: break
        }
    }

    /// Truncated head → `XMLParser` reports a parse error partway through. Flush
    /// the pending capture so a mid-tag cutoff still yields the text so far.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        flushPendingCapture()
    }
}
