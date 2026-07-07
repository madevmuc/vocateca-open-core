import Foundation

// MARK: - OPMLFeed

/// A single feed entry extracted from an OPML document.
public struct OPMLFeed: Sendable, Equatable {
    public let title: String
    public let feedURL: String

    public init(title: String, feedURL: String) {
        self.title = title
        self.feedURL = feedURL
    }
}

// MARK: - OPMLParser

/// Parses OPML XML into a flat, deduplicated list of ``OPMLFeed``.
///
/// Uses Foundation's `XMLParser` (SAX). Because SAX visits every element
/// regardless of nesting depth, category `<outline>` groups are handled
/// automatically — no manual recursion is required. Every `outline` element
/// carrying a non-empty `xmlUrl` attribute is collected as a feed; outlines
/// without one (category folders) are skipped.
///
/// Tolerant by design: malformed XML never throws or crashes — whatever was
/// collected before the parse error is returned (possibly empty).
public enum OPMLParser {
    public static func parse(_ data: Data) -> [OPMLFeed] {
        let delegate = OutlineCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()

        var seen = Set<String>()
        var result: [OPMLFeed] = []
        for feed in delegate.feeds where !seen.contains(feed.feedURL) {
            seen.insert(feed.feedURL)
            result.append(feed)
        }
        return result
    }

    /// Derives a non-empty title from a feed URL when no `text`/`title`
    /// attribute is present: the last path component without its extension,
    /// falling back to the host.
    static func deriveFromURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else {
            return urlString
        }
        let lastComponent = (components.path as NSString).lastPathComponent
        if !lastComponent.isEmpty {
            let withoutExtension = (lastComponent as NSString).deletingPathExtension
            if !withoutExtension.isEmpty {
                return withoutExtension
            }
            return lastComponent
        }
        if let host = components.host, !host.isEmpty {
            return host
        }
        return urlString
    }
}

// MARK: - OutlineCollector

/// `XMLParserDelegate` that collects every `outline` element with a
/// non-empty `xmlUrl` attribute, in document order.
private final class OutlineCollector: NSObject, XMLParserDelegate {
    var feeds: [OPMLFeed] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "outline" else { return }
        guard let feedURL = attributeDict["xmlUrl"], !feedURL.isEmpty else { return }

        let title = attributeDict["text"]
            ?? attributeDict["title"]
            ?? OPMLParser.deriveFromURL(feedURL)
        feeds.append(OPMLFeed(title: title, feedURL: feedURL))
    }

    // Tolerant: swallow parse errors, keep whatever was collected so far.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {}
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {}
}
