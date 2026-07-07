import XCTest
@testable import VocatecaCore

// MARK: - ModelTests

/// Tests for ``Show``, ``Settings``, ``Watchlist``, and ``SettingsStore``.
///
/// Two test layers:
/// (a) Curated-fixture decode tests — deterministic, always run.
/// (c) Round-trip idempotency — load → encode → load → assert Equatable.
final class ModelTests: XCTestCase {

    // MARK: - Bundle helpers

    private func fixtureURL(named name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "yaml",
            subdirectory: "Fixtures/yaml"
        ) else {
            throw XCTSkip("Fixture not found: Fixtures/yaml/\(name).yaml")
        }
        return url
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (a) Curated-fixture decode tests
    // MARK: ─────────────────────────────────────────

    // MARK: show_minimal — only slug/title/rss present; all others must default

    func testShowMinimalDefaults() throws {
        let url = try fixtureURL(named: "show_minimal")
        let wl  = try Watchlist.load(from: url)
        XCTAssertEqual(wl.shows.count, 1)
        let s = wl.shows[0]

        XCTAssertEqual(s.slug,  "my-show")
        XCTAssertEqual(s.title, "My Show")
        XCTAssertEqual(s.rss,   "https://example.com/feed.xml")

        // Python defaults
        XCTAssertEqual(s.whisperPrompt,         Show.defaultWhisperPrompt)
        XCTAssertEqual(s.enabled,               Show.defaultEnabled)
        XCTAssertNil(s.outputOverride)
        XCTAssertEqual(s.language,              Show.defaultLanguage)
        XCTAssertEqual(s.artworkUrl,            Show.defaultArtworkUrl)
        XCTAssertEqual(s.source,                Show.defaultSource)
        XCTAssertEqual(s.youtubeTranscriptPref, Show.defaultYoutubeTranscriptPref)
        XCTAssertEqual(s.skipShorts,            Show.defaultSkipShorts)
        XCTAssertEqual(s.autoVocab,             Show.defaultAutoVocab)
        XCTAssertEqual(s.minDurationSec,        Show.defaultMinDurationSec)
        XCTAssertEqual(s.maxDurationSec,        Show.defaultMaxDurationSec)
        XCTAssertEqual(s.notify,                Show.defaultNotify)

        // v2-only defaults
        XCTAssertEqual(s.igReels,         Show.defaultIgReels)
        XCTAssertEqual(s.igPosts,         Show.defaultIgPosts)
        XCTAssertEqual(s.igStories,       Show.defaultIgStories)
        XCTAssertEqual(s.igBackfillMode,  Show.defaultIgBackfillMode)
        XCTAssertEqual(s.igBackfillN,     Show.defaultIgBackfillN)

        // Unified backfill policy defaults (no legacy ig_backfill_mode key present).
        XCTAssertEqual(s.backfillMode,  Show.defaultBackfillMode)
        XCTAssertEqual(s.backfillN,     Show.defaultBackfillN)
        XCTAssertEqual(s.backfillSince, Show.defaultBackfillSince)
    }

    // MARK: show_full — every key set to non-defaults; assert exact values

    func testShowFullValues() throws {
        let url = try fixtureURL(named: "show_full")
        let wl  = try Watchlist.load(from: url)
        XCTAssertEqual(wl.shows.count, 1)
        let s = wl.shows[0]

        XCTAssertEqual(s.slug,                "full-show")
        XCTAssertEqual(s.title,               "Full Show")
        XCTAssertEqual(s.rss,                 "https://example.com/full.xml")
        XCTAssertEqual(s.whisperPrompt,       "Custom prompt here.")
        XCTAssertEqual(s.enabled,             false)
        XCTAssertEqual(s.outputOverride,      "/tmp/out")
        XCTAssertEqual(s.language,            "en")
        XCTAssertEqual(s.artworkUrl,          "https://example.com/art.jpg")
        XCTAssertEqual(s.source,              "youtube")
        XCTAssertEqual(s.youtubeTranscriptPref, "whisper")
        XCTAssertEqual(s.skipShorts,          false)
        XCTAssertEqual(s.autoVocab,           true)
        XCTAssertEqual(s.minDurationSec,      120)
        XCTAssertEqual(s.maxDurationSec,      7200)
        XCTAssertEqual(s.notify,              false)

        // v2-only
        XCTAssertEqual(s.igReels,       false)
        XCTAssertEqual(s.igPosts,       false)
        XCTAssertEqual(s.igStories,     false)
        XCTAssertEqual(s.igBackfillMode, "last_n")
        XCTAssertEqual(s.igBackfillN,   10)

        // Unified backfill policy — no `backfill_mode` key present, but legacy
        // `ig_backfill_mode: last_n` IS present, so the generic field is seeded
        // from it (last_n → last_n) and backfillN from igBackfillN (10).
        XCTAssertEqual(s.backfillMode, "last_n")
        XCTAssertEqual(s.backfillN,    10)
        XCTAssertEqual(s.backfillSince, Show.defaultBackfillSince)
    }

    // MARK: settings_partial — a handful of keys; rest must default

    func testSettingsPartialDefaults() throws {
        let url  = try fixtureURL(named: "settings_partial")
        let text = try String(contentsOf: url, encoding: .utf8)
        let migratedText = try Settings.migratingLoadLevel(in: text)
        let settings = try SettingsStore.decode(from: migratedText)

        // Overridden values
        XCTAssertEqual(settings.outputRoot,       "/custom/path")
        XCTAssertEqual(settings.dailyCheckTime,   "14:30")
        XCTAssertEqual(settings.mp3RetentionDays, 14)
        XCTAssertEqual(settings.whisperModel,     "small")
        XCTAssertEqual(settings.notifyEvents, [
            "episode.transcribed": true,
            "run.finished":        false,
            "episode.failed":      true,
        ])

        // Spot-check defaults — the ones most likely to be tricky
        XCTAssertEqual(settings.autoStartQueue,          Settings.defaultAutoStartQueue)      // true
        XCTAssertEqual(settings.diarizationEnabled,      Settings.defaultDiarizationEnabled)  // true
        XCTAssertEqual(settings.confidenceThreshold,     Settings.defaultConfidenceThreshold) // 0.5
        XCTAssertEqual(settings.loadLevel,               Settings.defaultLoadLevel)            // "balanced"
        XCTAssertEqual(settings.obsidianVaultName,       Settings.defaultObsidianVaultName)   // "knowledge-hub"
        XCTAssertEqual(settings.exportRoot,              Settings.defaultExportRoot)           // "~/Downloads"
        XCTAssertEqual(settings.sourcesPodcasts,         Settings.defaultSourcesPodcasts)     // true
        XCTAssertEqual(settings.sourcesYoutube,          Settings.defaultSourcesYoutube)      // true
        XCTAssertEqual(settings.youtubeSkipShortsDefault, Settings.defaultYoutubeSkipShortsDefault) // true
        XCTAssertEqual(settings.webhooks.isEmpty, true)

        // v2-only defaults
        XCTAssertEqual(settings.sourcesInstagram,        Settings.defaultSourcesInstagram)    // false
        XCTAssertEqual(settings.instagramRate,           Settings.defaultInstagramRate)        // "normal"
        XCTAssertEqual(settings.proEntitlementStatus,    Settings.defaultProEntitlementStatus) // "unknown"
    }

    // MARK: watchlist_legacy — 2 shows, no v2 keys; assert clean load + v2 defaults

    func testWatchlistLegacyLoadsClean() throws {
        let url = try fixtureURL(named: "watchlist_legacy")
        let wl  = try Watchlist.load(from: url)
        XCTAssertEqual(wl.shows.count, 2)

        for show in wl.shows {
            // All v2-only fields must be at their defaults
            XCTAssertEqual(show.igReels,        Show.defaultIgReels,        "igReels default for \(show.slug)")
            XCTAssertEqual(show.igPosts,        Show.defaultIgPosts,        "igPosts default for \(show.slug)")
            XCTAssertEqual(show.igStories,      Show.defaultIgStories,      "igStories default for \(show.slug)")
            XCTAssertEqual(show.igBackfillMode, Show.defaultIgBackfillMode, "igBackfillMode default for \(show.slug)")
            XCTAssertEqual(show.igBackfillN,    Show.defaultIgBackfillN,    "igBackfillN default for \(show.slug)")
            XCTAssertEqual(show.backfillMode,   Show.defaultBackfillMode,   "backfillMode default for \(show.slug)")
            XCTAssertEqual(show.backfillN,      Show.defaultBackfillN,      "backfillN default for \(show.slug)")
            XCTAssertEqual(show.backfillSince,  Show.defaultBackfillSince,  "backfillSince default for \(show.slug)")
        }

        // Specific show values
        let p = wl.shows[0]
        XCTAssertEqual(p.slug,   "legacy-podcast")
        XCTAssertEqual(p.source, "podcast")
        XCTAssertEqual(p.language, "de")

        let y = wl.shows[1]
        XCTAssertEqual(y.slug,   "legacy-youtube")
        XCTAssertEqual(y.source, "youtube")
        XCTAssertEqual(y.youtubeTranscriptPref, "captions")
    }

    // MARK: includeVideos — mirrors skipShorts (v2-only YouTube Videos/Shorts toggle)

    func testShowIncludeVideosDefaultsTrueWhenKeyAbsent() throws {
        let url = try fixtureURL(named: "show_minimal")
        let wl  = try Watchlist.load(from: url)
        let s = wl.shows[0]
        XCTAssertEqual(s.includeVideos, Show.defaultIncludeVideos)
        XCTAssertEqual(s.includeVideos, true)
    }

    func testShowIncludeVideosRoundTrip() throws {
        let show = Show(
            slug: "shorts-only-show",
            title: "Shorts Only Show",
            rss: "https://example.com/feed.xml",
            skipShorts: false,
            includeVideos: false
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(show)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Show.self, from: data)

        XCTAssertEqual(decoded.includeVideos, false, "includeVideos=false must survive encode/decode round-trip")
        XCTAssertEqual(decoded.skipShorts, false)
        XCTAssertEqual(decoded, show)
    }

    // MARK: Settings time validator

    func testSettingsTimeValidatorRejects() {
        XCTAssertFalse(Settings.isValidHHMM("25:00"))
        XCTAssertFalse(Settings.isValidHHMM("9:00"))
        XCTAssertFalse(Settings.isValidHHMM("09:60"))
        XCTAssertFalse(Settings.isValidHHMM("ab:cd"))
        XCTAssertFalse(Settings.isValidHHMM(""))
    }

    func testSettingsTimeValidatorAccepts() {
        XCTAssertTrue(Settings.isValidHHMM("09:00"))
        XCTAssertTrue(Settings.isValidHHMM("23:59"))
        XCTAssertTrue(Settings.isValidHHMM("00:00"))
        XCTAssertTrue(Settings.isValidHHMM("19:30"))
    }

    func testSettingsInvalidTimeThrows() {
        let yaml = """
        daily_check_time: "25:00"
        """
        XCTAssertThrowsError(
            try SettingsStore.decode(from: yaml)
        ) { error in
            let description = "\(error)"
            XCTAssertTrue(description.contains("25:00"), "Error should mention the bad value: \(description)")
        }
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (c) Round-trip idempotency
    // MARK: ─────────────────────────────────────────

    func testShowFullRoundTrip() throws {
        let url = try fixtureURL(named: "show_full")
        let wl1 = try Watchlist.load(from: url)
        let yaml = try wl1.yamlString()
        // Write to temp, reload
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("show_full_rt_\(UUID().uuidString).yaml")
        try yaml.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wl2 = try Watchlist.load(from: tmp)
        XCTAssertEqual(wl1, wl2, "Round-trip broke equality for show_full fixture")
    }

    func testWatchlistLegacyRoundTrip() throws {
        let url = try fixtureURL(named: "watchlist_legacy")
        let wl1 = try Watchlist.load(from: url)
        let yaml = try wl1.yamlString()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("watchlist_legacy_rt_\(UUID().uuidString).yaml")
        try yaml.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wl2 = try Watchlist.load(from: tmp)
        XCTAssertEqual(wl1, wl2, "Round-trip broke equality for watchlist_legacy fixture")
    }

    func testSettingsPartialRoundTrip() throws {
        let url  = try fixtureURL(named: "settings_partial")
        let text = try String(contentsOf: url, encoding: .utf8)
        let migratedText = try Settings.migratingLoadLevel(in: text)
        let s1   = try SettingsStore.decode(from: migratedText)
        let yaml = try SettingsStore.yamlString(s1)
        let s2   = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s1, s2, "Round-trip broke equality for settings_partial fixture")
    }

    func testLiveWatchlistRoundTrip() throws {
        let wlURL = Paths.watchlistURL
        guard FileManager.default.fileExists(atPath: wlURL.path) else {
            throw XCTSkip("Real watchlist.yaml not found")
        }
        let wl1 = try Watchlist.load(from: wlURL)
        let yaml = try wl1.yamlString()
        let tmp  = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wl_rt_\(UUID().uuidString).yaml")
        try yaml.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wl2 = try Watchlist.load(from: tmp)
        XCTAssertEqual(wl1, wl2, "Round-trip broke equality for real watchlist")
    }

    func testLiveSettingsRoundTrip() throws {
        let settingsURL = Paths.settingsURL
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            throw XCTSkip("Real settings.yaml not found")
        }
        let s1   = try SettingsStore.load(from: settingsURL, persistDefaultOnMissing: false)
        let yaml = try SettingsStore.yamlString(s1)
        let s2   = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s1, s2, "Round-trip broke equality for real settings")
    }
}
