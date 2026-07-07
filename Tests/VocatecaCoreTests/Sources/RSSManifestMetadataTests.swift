import XCTest
@testable import VocatecaCore

// MARK: - RSSManifestMetadataTests

/// Unit tests for ``RSSManifest/parseFeedTitle(fromXML:)`` and
/// ``RSSManifest/parseFeedArtwork(fromXML:)``.
///
/// All tests use small inline XML literals — no network, no fixtures.
/// Run with: swift test --filter RSSManifestMetadataTests
final class RSSManifestMetadataTests: XCTestCase {

    // MARK: - parseFeedTitle

    func testParseFeedTitle_RSS_returnsChannelTitle() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>My Podcast Show</title>
            <item><title>Episode 1</title></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedTitle(fromXML: xml), "My Podcast Show")
    }

    func testParseFeedTitle_CDATA_returnsChannelTitle() {
        // Regression: podcast hosts (e.g. Captivate) CDATA-wrap the channel
        // <title>. The head parser must read CDATA the same as plain text —
        // otherwise the title comes back empty and the show displays its slug
        // after reconnect / refresh (while the artwork href still resolves).
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title><![CDATA[Immo Inside mit Dr. Peter Burnickl]]></title>
            <itunes:image href="https://artwork.example/cover.jpg"/>
            <item><title><![CDATA[Episode 1]]></title></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: xml)
        XCTAssertEqual(meta.title, "Immo Inside mit Dr. Peter Burnickl")
        XCTAssertEqual(meta.artworkURL, "https://artwork.example/cover.jpg")
    }

    func testParseFeedTitle_ignoresItemTitle() {
        // The <title> inside <item> must NOT be returned — only the channel-level title.
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Channel Title</title>
            <item>
              <title>Episode Title — should be ignored</title>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedTitle(fromXML: xml), "Channel Title")
    }

    func testParseFeedTitle_Atom_returnsFeedTitle() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>My Atom Feed</title>
          <entry><title>Entry 1</title></entry>
        </feed>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedTitle(fromXML: xml), "My Atom Feed")
    }

    func testParseFeedTitle_missingTitle_returnsEmpty() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <link>https://example.com</link>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedTitle(fromXML: xml), "")
    }

    func testParseFeedTitle_emptyData_returnsEmpty() {
        XCTAssertEqual(RSSManifest.parseFeedTitle(fromXML: Data()), "")
    }

    // MARK: - parseFeedArtwork

    func testParseFeedArtwork_itunesImage_preferred() {
        // itunes:image should be preferred over <image><url>
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Test</title>
            <itunes:image href="https://example.com/itunes-artwork.jpg"/>
            <image>
              <url>https://example.com/rss-image.jpg</url>
            </image>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "https://example.com/itunes-artwork.jpg")
    }

    func testParseFeedArtwork_fallsBackToImageUrl() {
        // When itunes:image is absent, fall back to <image><url>
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Test</title>
            <image>
              <url>https://example.com/rss-image.jpg</url>
              <title>Test</title>
            </image>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "https://example.com/rss-image.jpg")
    }

    func testParseFeedArtwork_Atom_logo() {
        // Atom <logo> element
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <logo>https://example.com/logo.png</logo>
        </feed>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "https://example.com/logo.png")
    }

    func testParseFeedArtwork_Atom_iconFallback() {
        // Atom <icon> fallback when <logo> absent
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <icon>https://example.com/icon.png</icon>
        </feed>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "https://example.com/icon.png")
    }

    func testParseFeedArtwork_missingArtwork_returnsEmpty() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>No Artwork Feed</title>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "")
    }

    func testParseFeedArtwork_ignoresItemItunesImage() {
        // itunes:image inside an <item> must NOT be returned
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Test</title>
            <item>
              <title>Ep 1</title>
              <itunes:image href="https://example.com/episode-art.jpg"/>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: xml), "")
    }

    func testParseFeedArtwork_emptyData_returnsEmpty() {
        XCTAssertEqual(RSSManifest.parseFeedArtwork(fromXML: Data()), "")
    }

    // MARK: - parseFeedDescription

    func testParseFeedDescription_prefersItunesSummary() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <description>Plain description</description>
            <itunes:summary>The iTunes summary wins</itunes:summary>
            <item><description>Episode blurb — ignored</description></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: xml), "The iTunes summary wins")
    }

    func testParseFeedDescription_fallsBackToDescription() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Show</title>
            <description>A great show about things.</description>
            <item><title>Ep 1</title></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: xml), "A great show about things.")
    }

    func testParseFeedDescription_handlesCDATA() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <description><![CDATA[Rich <b>HTML</b> summary & more]]></description>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: xml),
                       "Rich <b>HTML</b> summary & more")
    }

    func testParseFeedDescription_ignoresItemDescription() {
        // Only the channel-level description must be returned.
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <item><description>Episode-only description</description></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: xml), "")
    }

    func testParseFeedDescription_atomSubtitle() {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <subtitle>An Atom feed subtitle.</subtitle>
          <entry><title>Entry 1</title></entry>
        </feed>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: xml), "An Atom feed subtitle.")
    }

    func testParseFeedDescription_emptyData_returnsEmpty() {
        XCTAssertEqual(RSSManifest.parseFeedDescription(fromXML: Data()), "")
    }

    // MARK: - parseFeedDescription — truncation tolerance (the empty-preview bug)

    func testParseFeedDescription_truncatedMidDescription_returnsPartialText() {
        // Simulates a byte-capped feed head that cuts off *inside* the channel
        // <description> — the closing </description> (and </channel></rss>) never
        // arrive, so XMLParser reports a parse error. The captured text so far
        // must still be returned rather than discarded (was the "—" preview bug).
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>#Gamechanger mit Toygar Cinar</title>
            <language>de-DE</language>
            <description>Der Podcast über Unternehmertum, Vertrieb und Erfolg. In jeder Folge spricht Toygar Cinar mit Gästen über ihre Wege, ihre Rückschläge und ihre größten Lektionen
        """.data(using: .utf8)!
        let desc = RSSManifest.parseFeedDescription(fromXML: xml)
        XCTAssertTrue(desc.hasPrefix("Der Podcast über Unternehmertum"),
                      "Truncated description should still return the captured prefix, got: \(desc)")
        XCTAssertTrue(desc.contains("ihre größten Lektionen"))
    }

    func testParseFeedDescription_truncatedMidItunesSummary_returnsPartialText() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Show</title>
            <itunes:summary>A long summary that gets cut off before the closing tag ever
        """.data(using: .utf8)!
        let desc = RSSManifest.parseFeedDescription(fromXML: xml)
        XCTAssertEqual(desc, "A long summary that gets cut off before the closing tag ever")
    }

    // MARK: - parseFeedLanguage

    func testParseFeedLanguage_RSS_returnsChannelLanguage() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Show</title>
            <language>de-DE</language>
            <item><title>Ep 1</title></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedLanguage(fromXML: xml), "de-DE")
    }

    func testParseFeedLanguage_missing_returnsEmpty() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Show</title></channel></rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedLanguage(fromXML: xml), "")
    }

    func testParseFeedLanguage_ignoresItemLanguage() {
        // A stray <language> inside an <item> must not be picked up.
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Show</title>
            <item><language>fr</language></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(RSSManifest.parseFeedLanguage(fromXML: xml), "")
    }

    // MARK: - parseFeedChannelMeta — description + language in one pass

    func testParseFeedChannelMeta_returnsBoth() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Show</title>
            <language>en-US</language>
            <itunes:summary>Great show.</itunes:summary>
            <item><title>Ep 1</title></item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        let meta = RSSManifest.parseFeedChannelMeta(fromXML: xml)
        XCTAssertEqual(meta.description, "Great show.")
        XCTAssertEqual(meta.language, "en-US")
    }

    // MARK: - languageDisplayName

    func testLanguageDisplayName_mapsToLocalisedName() {
        // Use an explicit English locale so the assertion is locale-stable.
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "de-DE", locale: en), "German")
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "en", locale: en), "English")
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "en-US", locale: en), "English")
    }

    func testLanguageDisplayName_germanLocaleShowsGermanNames() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "de", locale: de), "Deutsch")
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "en", locale: de), "Englisch")
    }

    func testLanguageDisplayName_unknownCode_returnsRaw() {
        let en = Locale(identifier: "en_US")
        // A nonsense subtag falls back to the raw code.
        XCTAssertEqual(RSSManifest.languageDisplayName(for: "zz-ZZ", locale: en), "zz-ZZ")
    }

    func testLanguageDisplayName_emptyCode_returnsNil() {
        XCTAssertNil(RSSManifest.languageDisplayName(for: ""))
        XCTAssertNil(RSSManifest.languageDisplayName(for: "   "))
    }
}
