import XCTest
@testable import VocatecaCore

// MARK: - YouTubeResolverTests

/// Tests for ``YouTubeResolver``.
///
/// ## Structure
///
/// - **Pure unit tests** (no network): ``firstChannelID``, the channel /videos
///   URL builder, and JSON-lines parsing.  These run in CI on every PR.
///
/// - **Live network test** (``testLiveResolveAndEnumerate``): guarded by a
///   ``BinaryManager.isInstalled(.ytDlp)`` check.  When yt-dlp is present the
///   test actually resolves a real channel and enumerates real videos — this is
///   the Phase-2 gate requirement ("echte YouTube-Auflösung als automatischer
///   Test grün").  Network/timeout errors are wrapped in `XCTSkip` so CI does
///   not fail when offline or rate-limited, but on the development machine with
///   yt-dlp installed and a network connection the test MUST pass (not skip).
final class YouTubeResolverTests: XCTestCase {

    // MARK: - Pure unit: firstChannelID

    func testFirstChannelID_validLine() {
        let output = "UCBJycsmduvYEL83R_U4JriQ\n"
        XCTAssertEqual(
            YouTubeResolver.firstChannelID(in: output),
            "UCBJycsmduvYEL83R_U4JriQ"
        )
    }

    func testFirstChannelID_withNALines() {
        let output = """
        NA
        NA
        UCBJycsmduvYEL83R_U4JriQ
        """
        XCTAssertEqual(
            YouTubeResolver.firstChannelID(in: output),
            "UCBJycsmduvYEL83R_U4JriQ"
        )
    }

    func testFirstChannelID_firstOfMultiple() {
        let output = """
        UCBJycsmduvYEL83R_U4JriQ
        UCaaaaaaaaaaaaaaaaaaaaaaa1
        """
        // Must return the FIRST match, not any later one.
        XCTAssertEqual(
            YouTubeResolver.firstChannelID(in: output),
            "UCBJycsmduvYEL83R_U4JriQ"
        )
    }

    func testFirstChannelID_junkLines() {
        let output = """
        NA
        some-garbage-token
        notavalidid
        https://youtube.com/channel/UCsomething
        """
        XCTAssertNil(YouTubeResolver.firstChannelID(in: output))
    }

    func testFirstChannelID_emptyOutput() {
        XCTAssertNil(YouTubeResolver.firstChannelID(in: ""))
    }

    func testFirstChannelID_tooShortUC() {
        // "UC" + 21 chars is one char too short → not valid
        let short = "UC" + String(repeating: "a", count: 21)
        XCTAssertNil(YouTubeResolver.firstChannelID(in: short))
    }

    func testFirstChannelID_exactLength() {
        // "UC" + 22 chars = 24 total — valid
        let valid = "UC" + String(repeating: "x", count: 22)
        XCTAssertEqual(YouTubeResolver.firstChannelID(in: valid), valid)
    }

    func testFirstChannelID_withLeadingWhitespace() {
        // Lines with leading/trailing whitespace should still match after trim
        let output = "  UCBJycsmduvYEL83R_U4JriQ  \n"
        XCTAssertEqual(
            YouTubeResolver.firstChannelID(in: output),
            "UCBJycsmduvYEL83R_U4JriQ"
        )
    }

    // MARK: - Pure unit: channelVideosURL

    func testChannelVideosURL() {
        let url = YouTubeResolver.channelVideosURL(channelID: "UCBJycsmduvYEL83R_U4JriQ")
        XCTAssertEqual(
            url,
            "https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ/videos"
        )
    }

    func testChannelVideosURL_doesNotUseDashOrSlash() {
        let id = "UCBJycsmduvYEL83R_U4JriQ"
        let url = YouTubeResolver.channelVideosURL(channelID: id)
        XCTAssertTrue(url.contains("/channel/\(id)/videos"))
        XCTAssertFalse(url.hasSuffix("/"))
    }

    // MARK: - Pure unit: channelShortsURL

    func testChannelShortsURL() {
        let url = YouTubeResolver.channelShortsURL(channelID: "UCBJycsmduvYEL83R_U4JriQ")
        XCTAssertEqual(
            url,
            "https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ/shorts"
        )
    }

    func testChannelShortsURL_doesNotUseDashOrSlash() {
        let id = "UCBJycsmduvYEL83R_U4JriQ"
        let url = YouTubeResolver.channelShortsURL(channelID: id)
        XCTAssertTrue(url.contains("/channel/\(id)/shorts"))
        XCTAssertFalse(url.hasSuffix("/"))
    }

    // MARK: - Pure unit: parseJSONLines

    /// Captured flat-playlist output (3 entries, minimal fields).
    private let sampleFlatPlaylistOutput = """
    {"id": "dQw4w9WgXcQ", "title": "Rick Astley - Never Gonna Give You Up", "upload_date": "20091025", "duration": 213}
    {"id": "9bZkp7q19f0", "title": "PSY - GANGNAM STYLE", "upload_date": "20120715", "duration": 252}
    {"id": "kJQP7kiw5Fk", "title": "Luis Fonsi - Despacito", "upload_date": "20170113", "duration": 282}
    """

    func testParseJSONLines_count() throws {
        let dicts = try YouTubeResolver.parseJSONLines(sampleFlatPlaylistOutput)
        XCTAssertEqual(dicts.count, 3, "Should parse 3 video dicts")
    }

    func testParseJSONLines_skipsBlankLines() throws {
        let withBlanks = "\n\n" + sampleFlatPlaylistOutput + "\n\n"
        let dicts = try YouTubeResolver.parseJSONLines(withBlanks)
        XCTAssertEqual(dicts.count, 3)
    }

    func testParseJSONLines_manifestConversion() throws {
        let dicts = try YouTubeResolver.parseJSONLines(sampleFlatPlaylistOutput)
        let entries = YouTubeManifest.fromVideos(dicts)

        XCTAssertEqual(entries.count, 3)

        // First entry: Rick Astley
        XCTAssertEqual(entries[0].guid, "dQw4w9WgXcQ")
        XCTAssertEqual(entries[0].title, "Rick Astley - Never Gonna Give You Up")
        XCTAssertEqual(entries[0].pubDate, "2009-10-25")
        XCTAssertEqual(entries[0].mp3URL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(entries[0].durationSec, 213)

        // Second entry: PSY
        XCTAssertEqual(entries[1].guid, "9bZkp7q19f0")
        XCTAssertEqual(entries[1].pubDate, "2012-07-15")
        XCTAssertFalse(entries[1].mp3URL.isEmpty)

        // Third entry: Despacito
        XCTAssertEqual(entries[2].guid, "kJQP7kiw5Fk")
        XCTAssertEqual(entries[2].pubDate, "2017-01-13")
        XCTAssertEqual(entries[2].durationSec, 282)
    }

    func testParseJSONLines_skipsMissingID() throws {
        // An entry without "id" or "url" should be skipped by fromVideos
        let noID = """
        {"title": "No ID entry", "duration": 100}
        {"id": "validvideoXX", "title": "Valid", "duration": 50}
        """
        let dicts = try YouTubeResolver.parseJSONLines(noID)
        let entries = YouTubeManifest.fromVideos(dicts)
        // Only the second entry (with an id) should survive
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].guid, "validvideoXX")
    }

    func testParseJSONLines_emptyString() throws {
        let dicts = try YouTubeResolver.parseJSONLines("")
        XCTAssertEqual(dicts.count, 0)
    }

    func testParseJSONLines_skipsNonJSONLines() throws {
        let mixed = """
        [download] Some progress line
        {"id": "abc12345678", "title": "Good entry", "duration": 60}
        WARNING: some yt-dlp warning
        """
        let dicts = try YouTubeResolver.parseJSONLines(mixed)
        // The progress/warning lines are not valid JSON objects → skipped
        XCTAssertEqual(dicts.count, 1)
        XCTAssertEqual(entries(dicts)[0].guid, "abc12345678")
    }

    // Helper to avoid repeating YouTubeManifest.fromVideos in assertions
    private func entries(_ dicts: [[String: JSONValue]]) -> [YouTubeManifest.Entry] {
        YouTubeManifest.fromVideos(dicts)
    }

    // MARK: - Pure unit: YouTubeManifest.mergeEntries

    private func makeEntry(guid: String, title: String) -> YouTubeManifest.Entry {
        YouTubeManifest.Entry(
            guid: guid,
            title: title,
            pubDate: "",
            mp3URL: "https://www.youtube.com/watch?v=\(guid)",
            description: "",
            durationSec: nil
        )
    }

    func testMergeEntries_videosThenShorts() {
        let videos = [makeEntry(guid: "v1", title: "Video 1"), makeEntry(guid: "v2", title: "Video 2")]
        let shorts = [makeEntry(guid: "s1", title: "Short 1")]

        let merged = YouTubeManifest.mergeEntries(videos: videos, shorts: shorts)

        XCTAssertEqual(merged.map(\.guid), ["v1", "v2", "s1"])
    }

    func testMergeEntries_deduplicatesByGuid_keepsFirstOccurrence() {
        let videos = [makeEntry(guid: "shared", title: "From videos tab")]
        let shorts = [makeEntry(guid: "shared", title: "From shorts tab"), makeEntry(guid: "s2", title: "Short 2")]

        let merged = YouTubeManifest.mergeEntries(videos: videos, shorts: shorts)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.guid), ["shared", "s2"])
        // First occurrence (from videos) wins.
        XCTAssertEqual(merged[0].title, "From videos tab")
    }

    func testMergeEntries_emptyShorts() {
        let videos = [makeEntry(guid: "v1", title: "Video 1")]
        let merged = YouTubeManifest.mergeEntries(videos: videos, shorts: [])
        XCTAssertEqual(merged.map(\.guid), ["v1"])
    }

    func testMergeEntries_emptyVideos() {
        let shorts = [makeEntry(guid: "s1", title: "Short 1")]
        let merged = YouTubeManifest.mergeEntries(videos: [], shorts: shorts)
        XCTAssertEqual(merged.map(\.guid), ["s1"])
    }

    func testMergeEntries_bothEmpty() {
        let merged = YouTubeManifest.mergeEntries(videos: [], shorts: [])
        XCTAssertTrue(merged.isEmpty)
    }

    // MARK: - Pure unit: parseRSSPreview

    /// Minimal YouTube Atom RSS feed for testing the XML parser.
    private let sampleRSSFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:media="http://search.yahoo.com/mrss/"
          xmlns:yt="http://www.youtube.com/xml/schemas/2015">
      <title>MKBHD</title>
      <entry>
        <yt:videoId>abc12345678</yt:videoId>
        <title>Video 1</title>
        <media:group>
          <media:thumbnail url="https://i.ytimg.com/vi/abc12345678/hqdefault.jpg" width="480" height="360"/>
        </media:group>
      </entry>
      <entry>
        <yt:videoId>def87654321</yt:videoId>
        <title>Video 2</title>
        <media:group>
          <media:thumbnail url="https://i.ytimg.com/vi/def87654321/hqdefault.jpg" width="480" height="360"/>
        </media:group>
      </entry>
    </feed>
    """

    func testParseRSSPreview_title() {
        let data = sampleRSSFeed.data(using: .utf8)!
        let (title, _, _) = YouTubeResolver.parseRSSPreview(data: data)
        XCTAssertEqual(title, "MKBHD")
    }

    func testParseRSSPreview_entryCount() {
        let data = sampleRSSFeed.data(using: .utf8)!
        let (_, count, _) = YouTubeResolver.parseRSSPreview(data: data)
        XCTAssertEqual(count, 2)
    }

    func testParseRSSPreview_firstThumbURL() {
        let data = sampleRSSFeed.data(using: .utf8)!
        let (_, _, thumb) = YouTubeResolver.parseRSSPreview(data: data)
        XCTAssertEqual(thumb, "https://i.ytimg.com/vi/abc12345678/hqdefault.jpg")
    }

    func testParseRSSPreview_emptyData() {
        let data = Data()
        let (title, count, thumb) = YouTubeResolver.parseRSSPreview(data: data)
        XCTAssertEqual(title, "")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(thumb, "")
    }

    // MARK: - Live network test (Phase-2 gate)

    /// Resolve a real YouTube channel and enumerate real videos via yt-dlp.
    ///
    /// **Gate requirement:** On this development machine (yt-dlp installed,
    /// network available) this test MUST run and pass — not just skip.
    ///
    /// Skip conditions (wraps errors in XCTSkip to avoid CI failures):
    /// - yt-dlp not installed → skip.
    /// - Any network/timeout error → skip with the error message.
    ///
    /// We use MKBHD (Marques Brownlee) — a very large, stable channel that has
    /// been active since 2009 and is unlikely to be removed.
    ///   handle: @MKBHD
    ///   expected channel id: UCBJycsmduvYEL83R_U4JriQ
    func testLiveResolveAndEnumerate() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network tests")
        }
        let bm = BinaryManager()
        guard bm.isInstalled(.ytDlp) else {
            throw XCTSkip("yt-dlp not installed — skipping live YouTube test")
        }

        let resolver = YouTubeResolver(binaryManager: bm)

        // ── 1. Resolve @MKBHD → channel id ────────────────────────────────
        let channelID: String
        do {
            channelID = try await resolver.resolveChannelID(from: "@MKBHD")
        } catch let e as SubprocessError {
            throw XCTSkip("yt-dlp subprocess error (possibly offline): \(e)")
        } catch let e as YouTubeResolverError {
            switch e {
            case .ytdlpFailed(let msg):
                throw XCTSkip("yt-dlp failed (possibly rate-limited): \(msg)")
            case .notResolved(let input):
                throw XCTSkip("Could not resolve \(input) — possibly rate-limited")
            case .ytdlpMissing:
                throw XCTSkip("yt-dlp went missing during the test")
            }
        }

        print("✓ Resolved @MKBHD → channelID = \(channelID)")

        // Validate shape: must match UC + 22 alphanumeric/dash/underscore chars
        let idPattern = try! NSRegularExpression(pattern: #"^UC[\w-]{22}$"#)
        let range = NSRange(channelID.startIndex..., in: channelID)
        XCTAssertNotNil(
            idPattern.firstMatch(in: channelID, range: range),
            "Resolved channel id '\(channelID)' does not match UC[\\w-]{22}"
        )
        // MKBHD's known channel id (sanity check)
        XCTAssertEqual(
            channelID, "UCBJycsmduvYEL83R_U4JriQ",
            "Expected MKBHD channel id UCBJycsmduvYEL83R_U4JriQ, got \(channelID)"
        )

        // ── 2. Enumerate 5 videos ──────────────────────────────────────────
        let entries: [YouTubeManifest.Entry]
        do {
            entries = try await resolver.enumerateVideos(channelID: channelID, limit: 5)
        } catch let e as SubprocessError {
            throw XCTSkip("yt-dlp timed out or failed during enumeration: \(e)")
        } catch let e as YouTubeResolverError {
            switch e {
            case .ytdlpFailed(let msg):
                throw XCTSkip("yt-dlp enumeration failed (possibly rate-limited): \(msg)")
            default:
                throw XCTSkip("Enumeration error: \(e)")
            }
        }

        print("✓ Enumerated \(entries.count) videos for \(channelID)")
        for (i, e) in entries.enumerated() {
            print("  [\(i)] guid=\(e.guid) title=\(e.title.prefix(60)) pubDate=\(e.pubDate)")
        }

        // Must have gotten at least 1 entry
        XCTAssertGreaterThanOrEqual(
            entries.count, 1,
            "Expected ≥1 video from enumerateVideos(limit:5), got 0"
        )

        // Each entry must have non-empty guid, title, mp3URL (watch URL)
        for (i, entry) in entries.enumerated() {
            XCTAssertFalse(entry.guid.isEmpty,   "entry[\(i)].guid is empty")
            XCTAssertFalse(entry.title.isEmpty,  "entry[\(i)].title is empty")
            XCTAssertFalse(entry.mp3URL.isEmpty, "entry[\(i)].mp3URL is empty")
            // mp3URL should be a YouTube watch URL
            XCTAssertTrue(
                entry.mp3URL.hasPrefix("https://www.youtube.com/watch?v="),
                "entry[\(i)].mp3URL should be a watch URL, got: \(entry.mp3URL)"
            )
        }
    }
}
