import XCTest
@testable import VocatecaCore

/// Golden-fixture tests for the YouTube oracle ports (Phase 2).
///
/// Each test loads the corresponding JSON fixture produced by the Python reference
/// oracle and asserts byte-for-byte equality for every case. The fixture files live
/// at `Tests/VocatecaCoreTests/Fixtures/oracle/` and are bundled via the
/// `resources: [.copy("Fixtures")]` declaration in Package.swift.
///
/// Do NOT edit the JSON fixtures to make tests pass — the Python oracle is authoritative.
final class OracleYouTubeTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixtureURL(named filename: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "Fixtures/oracle"
        ) else {
            XCTFail("Fixture not found in bundle: Fixtures/oracle/\(filename).json")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - youtube_parse_url

    func testParseURL() throws {
        // Fixture schema: [{input, kind, value} | {input, error: true}]
        struct ParseCase: Decodable {
            let input: String
            let kind: String?
            let value: String?
            let error: Bool?
        }
        let data = try Data(contentsOf: fixtureURL(named: "youtube_parse_url"))
        let cases = try JSONDecoder().decode([ParseCase].self, from: data)
        XCTAssertFalse(cases.isEmpty, "youtube_parse_url fixture is empty")
        var failures = 0
        for c in cases {
            if c.error == true {
                // Expect a throw
                do {
                    let got = try YouTubeURL.parse(c.input)
                    XCTFail("""
                        parseURL should have thrown for \(c.input.debugDescription) \
                        but returned kind=\(got.kind.rawValue) value=\(got.value.debugDescription)
                        """)
                    failures += 1
                } catch {
                    // expected
                }
            } else {
                // Expect success
                guard let expectedKindRaw = c.kind, let expectedValue = c.value else {
                    XCTFail("Fixture case missing kind/value for input \(c.input.debugDescription)")
                    failures += 1
                    continue
                }
                do {
                    let got = try YouTubeURL.parse(c.input)
                    if got.kind.rawValue != expectedKindRaw || got.value != expectedValue {
                        XCTFail("""
                            parseURL mismatch for \(c.input.debugDescription):
                              expected kind=\(expectedKindRaw) value=\(expectedValue.debugDescription)
                              got      kind=\(got.kind.rawValue) value=\(got.value.debugDescription)
                            """)
                        failures += 1
                    }
                } catch {
                    XCTFail("""
                        parseURL threw for \(c.input.debugDescription) \
                        but expected kind=\(expectedKindRaw) value=\(expectedValue.debugDescription): \(error)
                        """)
                    failures += 1
                }
            }
        }
        if failures == 0 {
            print("parseURL: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - youtube_rss_urls

    func testRSSURLs() throws {
        // Fixture schema: [{kind, input, output}]
        struct RSSCase: Decodable {
            let kind: String
            let input: String
            let output: String
        }
        let data = try Data(contentsOf: fixtureURL(named: "youtube_rss_urls"))
        let cases = try JSONDecoder().decode([RSSCase].self, from: data)
        XCTAssertFalse(cases.isEmpty, "youtube_rss_urls fixture is empty")
        var failures = 0
        for c in cases {
            let got: String
            switch c.kind {
            case "rss_channel":
                got = YouTubeURL.rssURL(forChannelID: c.input)
            case "rss_playlist":
                got = YouTubeURL.rssURL(forPlaylistID: c.input)
            case "channel_id_from_feed_url":
                got = YouTubeURL.channelID(fromFeedURL: c.input)
            default:
                XCTFail("Unknown fixture kind: \(c.kind)")
                failures += 1
                continue
            }
            if got != c.output {
                XCTFail("""
                    rssURLs[\(c.kind)] mismatch:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("rssURLs: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - youtube_manifest_from_videos

    func testManifestFromVideos() throws {
        // Fixture schema: [{input: {video dict as JSONValue object}, output: {manifest dict}}]
        // We decode the outer structure with JSONValue to handle heterogeneous input.
        struct ManifestCase: Decodable {
            let input: [String: JSONValue]
            let output: ManifestOutput
        }
        struct ManifestOutput: Decodable {
            let guid: String
            let title: String
            let pubDate: String
            let mp3_url: String
            let description: String
            let duration_sec: Int?
        }

        let data = try Data(contentsOf: fixtureURL(named: "youtube_manifest_from_videos"))
        let cases = try JSONDecoder().decode([ManifestCase].self, from: data)
        XCTAssertFalse(cases.isEmpty, "youtube_manifest_from_videos fixture is empty")
        var failures = 0

        for (idx, c) in cases.enumerated() {
            // Run each input independently through fromVideos.
            let results = YouTubeManifest.fromVideos([c.input])
            guard results.count == 1 else {
                XCTFail("case[\(idx)]: fromVideos returned \(results.count) entries, expected 1")
                failures += 1
                continue
            }
            let got = results[0]
            let exp = c.output
            var mismatches: [String] = []
            if got.guid        != exp.guid        { mismatches.append("guid: got \(got.guid.debugDescription) expected \(exp.guid.debugDescription)") }
            if got.title       != exp.title       { mismatches.append("title: got \(got.title.debugDescription) expected \(exp.title.debugDescription)") }
            if got.pubDate     != exp.pubDate     { mismatches.append("pubDate: got \(got.pubDate.debugDescription) expected \(exp.pubDate.debugDescription)") }
            if got.mp3URL      != exp.mp3_url     { mismatches.append("mp3_url: got \(got.mp3URL.debugDescription) expected \(exp.mp3_url.debugDescription)") }
            if got.description != exp.description { mismatches.append("description: got \(got.description.debugDescription) expected \(exp.description.debugDescription)") }
            if got.durationSec != exp.duration_sec { mismatches.append("duration_sec: got \(String(describing: got.durationSec)) expected \(String(describing: exp.duration_sec))") }
            if !mismatches.isEmpty {
                XCTFail("case[\(idx)] manifest mismatch:\n  " + mismatches.joined(separator: "\n  "))
                failures += 1
            }
        }
        if failures == 0 {
            print("manifestFromVideos: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - youtube_classify

    func testClassify() throws {
        // Fixture schema: [{input: string | object, category: string, message: string}]
        // We use JSONValue for the polymorphic `input` field.
        struct ClassifyCase: Decodable {
            let input: JSONValue    // either .string or .object([String: JSONValue])
            let category: String
            let message: String
        }

        let data = try Data(contentsOf: fixtureURL(named: "youtube_classify"))
        let cases = try JSONDecoder().decode([ClassifyCase].self, from: data)
        XCTAssertFalse(cases.isEmpty, "youtube_classify fixture is empty")
        var failures = 0

        for (idx, c) in cases.enumerated() {
            let gotCategory: String
            let gotMessage: String
            switch c.input {
            case .string(let s):
                (gotCategory, gotMessage) = YouTubeClassify.classify(errorText: s)
            case .object(let dict):
                (gotCategory, gotMessage) = YouTubeClassify.classify(meta: dict)
            default:
                XCTFail("case[\(idx)]: unexpected input type in classify fixture")
                failures += 1
                continue
            }
            if gotCategory != c.category || gotMessage != c.message {
                XCTFail("""
                    classify case[\(idx)] mismatch:
                      input:    \(c.input)
                      expected: (\(c.category.debugDescription), \(c.message.debugDescription))
                      got:      (\(gotCategory.debugDescription), \(gotMessage.debugDescription))
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("classify: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - caption_source_chain

    func testCaptionSourceChain() throws {
        // Fixture schema: [{pref, fallback_mode, chain: [string]}]
        struct ChainCase: Decodable {
            let pref: String
            let fallback_mode: String
            let chain: [String]
        }

        let data = try Data(contentsOf: fixtureURL(named: "caption_source_chain"))
        let cases = try JSONDecoder().decode([ChainCase].self, from: data)
        XCTAssertFalse(cases.isEmpty, "caption_source_chain fixture is empty")
        var failures = 0

        for c in cases {
            let got = CaptionFallback.sourceChain(pref: c.pref, fallbackMode: c.fallback_mode)
            if got != c.chain {
                XCTFail("""
                    captionSourceChain mismatch:
                      pref=\(c.pref.debugDescription) fallbackMode=\(c.fallback_mode.debugDescription)
                      expected: \(c.chain)
                      got:      \(got)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("captionSourceChain: all \(cases.count) cases passed ✓")
        }
    }
}
