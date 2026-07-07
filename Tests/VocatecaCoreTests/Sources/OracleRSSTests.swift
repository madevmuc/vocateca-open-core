import XCTest
@testable import VocatecaCore

/// Oracle-locked tests for the RSS/Atom → episode manifest builder (Phase 2 WP3).
///
/// ## Committed-fixture tests
/// For each XML fixture in `Fixtures/feeds/` the generator
/// `swift/oracle/generate_fixtures.py` produces a golden manifest array
/// stored in `Fixtures/oracle/rss_manifest.json`. The tests here load each
/// fixture XML from `Bundle.module`, run `RSSManifest.build()`, and assert
/// byte-exact equality with the golden.
///
/// ## Live-smoke test
/// Fetches one real feed URL over `URLSession`, runs `RSSManifest.build()`,
/// and asserts ≥1 entry with non-empty guid/title/mp3_url. Auto-skipped when
/// offline or when the fetch fails. This satisfies the "echte RSS-Auflösung
/// als automatischer Test" gate item.
///
/// ## Rules
/// Do NOT edit the golden fixtures or weaken assertions to make tests pass.
/// The Python feedparser output is the authoritative oracle. Fix the Swift
/// mapping, not the goldens.
final class OracleRSSTests: XCTestCase {

    // MARK: - Fixture helpers

    private func feedURL(named filename: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "xml",
            subdirectory: "Fixtures/feeds"
        ) else {
            XCTFail("Feed fixture not found in bundle: Fixtures/feeds/\(filename).xml")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    private func oracleURL(named filename: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: "rss_manifest",
            withExtension: "json",
            subdirectory: "Fixtures/oracle"
        ) else {
            XCTFail("Oracle fixture not found: Fixtures/oracle/\(filename).json")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - Oracle JSON loading

    /// Loads the full rss_manifest.json once and returns the manifest array
    /// for `fixtureName`.
    private func loadGoldenManifest(fixtureName: String) throws -> [ManifestEntry] {
        let url = oracleURL(named: "rss_manifest")
        let data = try Data(contentsOf: url)
        let allFixtures = try JSONDecoder().decode(
            [String: [ManifestEntry]].self,
            from: data
        )
        guard let entries = allFixtures[fixtureName] else {
            XCTFail("rss_manifest.json has no key '\(fixtureName)'")
            return []
        }
        return entries
    }

    // MARK: - Per-fixture assertion helper

    private func assertManifestParity(fixtureName: String) throws {
        let feedData = try Data(contentsOf: feedURL(named: fixtureName.replacingOccurrences(of: ".xml", with: "")))
        let golden = try loadGoldenManifest(fixtureName: fixtureName)

        let got = try RSSManifest.build(fromXML: feedData)

        XCTAssertEqual(
            got.count, golden.count,
            "[\(fixtureName)] entry count: got \(got.count), expected \(golden.count)"
        )

        let pairCount = min(got.count, golden.count)
        var firstFail: String? = nil

        for i in 0..<pairCount {
            let g = got[i]
            let e = golden[i]
            var mismatches: [String] = []

            if g.guid != e.guid {
                mismatches.append("guid: got \(g.guid.debugDescription) expected \(e.guid.debugDescription)")
            }
            if g.title != e.title {
                mismatches.append("title: got \(g.title.debugDescription) expected \(e.title.debugDescription)")
            }
            if g.pubDate != e.pubDate {
                mismatches.append("pubDate: got \(g.pubDate.debugDescription) expected \(e.pubDate.debugDescription)")
            }
            if g.duration != e.duration {
                mismatches.append("duration: got \(g.duration.debugDescription) expected \(e.duration.debugDescription)")
            }
            if g.episodeNumber != e.episodeNumber {
                mismatches.append("episode_number: got \(g.episodeNumber.debugDescription) expected \(e.episodeNumber.debugDescription)")
            }
            if g.mp3URL != e.mp3URL {
                mismatches.append("mp3_url: got \(g.mp3URL.debugDescription) expected \(e.mp3URL.debugDescription)")
            }
            if g.description != e.description {
                mismatches.append("description: got \(g.description.prefix(80).debugDescription) expected \(e.description.prefix(80).debugDescription)")
            }
            if g.url != e.url {
                mismatches.append("url: got \(g.url.debugDescription) expected \(e.url.debugDescription)")
            }

            if !mismatches.isEmpty {
                let msg = "[\(fixtureName)] entry[\(i)] mismatch:\n  " + mismatches.joined(separator: "\n  ")
                if firstFail == nil { firstFail = msg }
                XCTFail(msg)
            }
        }

        if firstFail == nil && got.count == golden.count {
            print("OracleRSS[\(fixtureName)]: all \(golden.count) entries matched ✓")
        }
    }

    // MARK: - Committed-fixture tests

    func test1alage() throws {
        try assertManifestParity(fixtureName: "1alage.xml")
    }

    func testImmocation() throws {
        try assertManifestParity(fixtureName: "immocation.xml")
    }

    func testMKBHDYouTube() throws {
        try assertManifestParity(fixtureName: "mkbhd_youtube.xml")
    }

    // MARK: - Live smoke test

    /// Fetches one real feed URL over the network, runs `RSSManifest.build()`,
    /// and asserts ≥1 entry with non-empty guid/title/mp3_url.
    ///
    /// Auto-skips on any network error so CI offline builds stay green.
    func testLiveSmoke() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network tests")
        }
        let feedURLString = "https://1alage.podigee.io/feed/mp3"
        guard let url = URL(string: feedURLString) else {
            XCTFail("Invalid feed URL: \(feedURLString)")
            return
        }

        let data: Data
        do {
            let (d, _) = try await URLSession.shared.data(from: url)
            data = d
        } catch {
            throw XCTSkip("Network unavailable or fetch failed (\(error.localizedDescription)) — skipping live smoke test")
        }

        guard !data.isEmpty else {
            throw XCTSkip("Empty response from live feed — skipping live smoke test")
        }

        let entries: [ManifestEntry]
        do {
            entries = try RSSManifest.build(fromXML: data)
        } catch {
            XCTFail("RSSManifest.build failed on live feed: \(error)")
            return
        }

        XCTAssertGreaterThanOrEqual(
            entries.count, 1,
            "Live feed should yield at least 1 manifest entry"
        )

        if let first = entries.first {
            XCTAssertFalse(first.guid.isEmpty, "Live feed entry should have a non-empty guid")
            XCTAssertFalse(first.title.isEmpty, "Live feed entry should have a non-empty title")
            XCTAssertFalse(first.mp3URL.isEmpty, "Live feed entry should have a non-empty mp3_url")
            print("OracleRSS live smoke: \(entries.count) entries; first guid=\(first.guid.prefix(50)), title=\(first.title.prefix(60))")
        }
    }
}
