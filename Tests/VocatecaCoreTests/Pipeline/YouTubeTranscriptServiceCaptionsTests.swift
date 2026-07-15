import XCTest
@testable import VocatecaCore

// MARK: - YouTubeTranscriptServiceCaptionsTests
//
// `YouTubeTranscriptService.captions(forVideoURL:)`: manifest-driven,
// captions-first single-video transcript extraction — ONE manifest+meta
// probe (`captionFetcher.listManifest`), select one track via
// `CaptionLanguageMatcher`, fetch exactly that one — backed by the
// `CaptionFetching` fake so this exercises zero network. (Replaces the old
// multi-attempt manual-orig/manual-any/auto-orig/auto-any cascade, whose
// "-any" steps caused the P4 perf explosion on videos with hundreds of
// auto-translate caption languages; and the later two-call listTracks+
// fetchMeta pairing, which the P-perf fix folds into this single
// `listManifest` call.)

final class YouTubeTranscriptServiceCaptionsTests: XCTestCase {

    // MARK: - Fixtures

    /// Design doc's own 2-cue VTT example (`docs/superpowers/specs/2026-07-14-yt-export-explorer-design.md`).
    private static let fixtureVTT = """
    WEBVTT

    00:00:00.000 --> 00:00:04.120
    Hallo und willkommen

    00:00:04.120 --> 00:00:08.400
    Danke fürs Einladen
    """

    private static let fixtureMeta = YouTubeVideoMeta(
        videoID: "dQw4w9WgXcQ",
        title: "Never Gonna Give You Up",
        channelID: "UCuAXFkgsw1L7xaCfnd5JJOw",
        channelHandle: "@RickAstleyYT"
    )

    private static let videoURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    private static let manualDE = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false)
    private static let autoDE = CaptionTrack(languageCode: "de", displayName: "German (auto-generated)", isAuto: true)
    private static let manualEN = CaptionTrack(languageCode: "en", displayName: "English", isAuto: false)

    // MARK: - manual found

    func testCaptions_manualFound_returnsSourceCaptions() async throws {
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN], meta: Self.fixtureMeta,
            content: [Self.manualEN: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(transcript.title, "Never Gonna Give You Up")
        XCTAssertEqual(transcript.channelID, "UCuAXFkgsw1L7xaCfnd5JJOw")
        XCTAssertEqual(transcript.channelHandle, "@RickAstleyYT")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.source, .captions)
        XCTAssertEqual(transcript.captionsAuto, false, "manual captions must not be flagged as auto-generated")
    }

    // MARK: - only an auto track exists

    func testCaptions_onlyAutoTrackAvailable_returnsAutoCaptions() async throws {
        let autoEN = CaptionTrack(languageCode: "en", displayName: "English (auto-generated)", isAuto: true)
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [autoEN], meta: Self.fixtureMeta,
            content: [autoEN: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.source, .captions)
        XCTAssertEqual(transcript.captionsAuto, true, "the only available track being auto must be flagged as auto")
    }

    // MARK: - manifest empty -> nil (not thrown)

    func testCaptions_emptyManifest_returnsNil() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [], meta: Self.fixtureMeta)

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        XCTAssertNil(result)
    }

    // MARK: - track selected but fetch fails -> nil (not thrown)

    func testCaptions_selectedTrackFetchFails_returnsNil() async throws {
        // Track is listed in the manifest but not scripted in `content`/
        // `httpContent` -> both fetchTrackViaHTTP and fetchTrack return nil,
        // mirroring an HTTP failure falling back to a yt-dlp download
        // failure/timeout for the one selected track.
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [Self.manualEN], meta: Self.fixtureMeta)

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        XCTAssertNil(result)
    }

    // MARK: - manifest has no meta (still returns transcript)

    func testCaptions_manifestHasNoMeta_stillReturnsTranscript() async throws {
        // No `meta:` scripted for this video -> `listManifest` returns nil
        // meta, mirroring a `--dump-json` line yt-dlp couldn't fully parse
        // metadata out of (or a manifest probe whose id/title fields were
        // blank). Captions still load — metadata is best-effort.
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN], content: [Self.manualEN: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.title, "dQw4w9WgXcQ")
        XCTAssertNil(transcript.channelID)
        XCTAssertNil(transcript.channelHandle)
        XCTAssertEqual(transcript.segments.count, 2)
    }

    // MARK: - manual-in-originalLanguage preferred + language populated

    func testCaptions_manualInOriginalLanguage_preferredAndLanguagePopulated() async throws {
        let metaWithLang = YouTubeVideoMeta(
            videoID: Self.fixtureMeta.videoID,
            title: Self.fixtureMeta.title,
            channelID: Self.fixtureMeta.channelID,
            channelHandle: Self.fixtureMeta.channelHandle,
            language: "de"
        )
        // Manifest has both a German manual track and an English manual
        // track; original language "de" must steer selection to German.
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN, Self.manualDE], meta: metaWithLang,
            content: [Self.manualDE: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.language, "de")
        XCTAssertEqual(transcript.captionsAuto, false)
        // Exactly one manifest probe (tracks + meta together) + one fetch of
        // the selected track — no multi-attempt cascade, no separate
        // metadata subprocess.
        XCTAssertEqual(captionFetcher.listManifestCalls, [Self.videoURL])
        XCTAssertEqual(captionFetcher.fetchCalls, [
            FakeCaptionFetcher.FetchCall(videoURL: Self.videoURL, track: Self.manualDE),
        ])
    }

    // MARK: - region mismatch: metadata "de" resolves to manual track "de-DE" (P6-EXT)

    func testCaptions_originalLanguageRegionMismatch_resolvesToRegionalManualTrack() async throws {
        let metaWithLang = YouTubeVideoMeta(
            videoID: Self.fixtureMeta.videoID,
            title: Self.fixtureMeta.title,
            channelID: Self.fixtureMeta.channelID,
            channelHandle: Self.fixtureMeta.channelHandle,
            language: "de"
        )
        let manualDEDE = CaptionTrack(languageCode: "de-DE", displayName: "German (Germany)", isAuto: false)
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [manualDEDE], meta: metaWithLang,
            content: [manualDEDE: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.language, "de-DE",
                        "metadata 'de' must base-match the manifest's 'de-DE' manual track, not miss it")
        XCTAssertEqual(transcript.captionsAuto, false)
    }

    // MARK: - falls back to auto when no manual track exists at all

    func testCaptions_noManualTrack_fallsBackToAuto() async throws {
        let metaWithLang = YouTubeVideoMeta(
            videoID: Self.fixtureMeta.videoID,
            title: Self.fixtureMeta.title,
            channelID: Self.fixtureMeta.channelID,
            channelHandle: Self.fixtureMeta.channelHandle,
            language: "de"
        )
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.autoDE], meta: metaWithLang,
            content: [Self.autoDE: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.captionsAuto, true)
        XCTAssertEqual(transcript.language, "de")
    }

    // MARK: - originalLanguage unknown (nil) -> falls back to first manual track

    func testCaptions_originalLanguageUnknown_fallsBackToFirstManualTrack() async throws {
        // fixtureMeta has no `language` — mirrors metadata that predates this
        // field, or a video yt-dlp couldn't determine a language for.
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN], meta: Self.fixtureMeta,
            content: [Self.manualEN: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: nil,
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(transcript.captionsAuto, false)
    }

    // MARK: - fetch-by-language override picks a non-default track

    func testCaptions_explicitDesiredLanguage_overridesOriginalLanguageDefault() async throws {
        let metaWithLang = YouTubeVideoMeta(
            videoID: Self.fixtureMeta.videoID,
            title: Self.fixtureMeta.title,
            channelID: Self.fixtureMeta.channelID,
            channelHandle: Self.fixtureMeta.channelHandle,
            language: "de"
        )
        // Original language is German, but the caller (a language-picker UI)
        // explicitly asks for English.
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualDE, Self.manualEN], meta: metaWithLang,
            content: [Self.manualEN: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, desiredLanguage: "en",
            captionFetcher: captionFetcher
        )

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(captionFetcher.fetchCalls, [
            FakeCaptionFetcher.FetchCall(videoURL: Self.videoURL, track: Self.manualEN),
        ])
    }

    // MARK: - playlist URL throws

    func testCaptions_playlistURL_throws() async throws {
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN], content: [Self.manualEN: Self.fixtureVTT])
        let playlistURL = "https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvw"

        do {
            _ = try await YouTubeTranscriptService.captions(
                forVideoURL: playlistURL, desiredLanguage: nil,
                captionFetcher: captionFetcher
            )
            XCTFail("expected notAVideoURL to be thrown")
        } catch YouTubeTranscriptError.notAVideoURL(let url) {
            XCTAssertEqual(url, playlistURL)
        }
    }

    // MARK: - captionsWithTracks(forVideoURL:) single-call path

    /// `captionsWithTracks` must return the same default-selected transcript
    /// AND the manifest's track list from exactly ONE `listManifest` call —
    /// this is the Explorer's `load()` fast path.
    func testCaptionsWithTracks_returnsTranscriptAndManifestFromOneCall() async throws {
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [Self.manualEN, Self.autoDE], meta: Self.fixtureMeta,
            content: [Self.manualEN: Self.fixtureVTT])

        let (result, tracks) = try await YouTubeTranscriptService.captionsWithTracks(
            forVideoURL: Self.videoURL, captionFetcher: captionFetcher)

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(transcript.captionsAuto, false)
        XCTAssertEqual(tracks, [Self.manualEN, Self.autoDE])
        XCTAssertEqual(captionFetcher.listManifestCalls, [Self.videoURL],
                        "exactly one manifest probe for both the transcript and the picker's track list")
    }

    func testCaptionsWithTracks_emptyManifest_returnsNilTranscriptAndEmptyTracks() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [], meta: Self.fixtureMeta)

        let (result, tracks) = try await YouTubeTranscriptService.captionsWithTracks(
            forVideoURL: Self.videoURL, captionFetcher: captionFetcher)

        XCTAssertNil(result)
        XCTAssertEqual(tracks, [])
    }

    func testCaptionsWithTracks_playlistURL_throws() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [Self.manualEN])
        let playlistURL = "https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvw"

        do {
            _ = try await YouTubeTranscriptService.captionsWithTracks(
                forVideoURL: playlistURL, captionFetcher: captionFetcher)
            XCTFail("expected notAVideoURL to be thrown")
        } catch YouTubeTranscriptError.notAVideoURL(let url) {
            XCTAssertEqual(url, playlistURL)
        }
    }

    // MARK: - captions(forVideoURL:track:) known-track direct-HTTP path

    /// The known-track path must prefer `fetchTrackViaHTTP` over the yt-dlp
    /// `fetchTrack` fallback, and must NOT call `listManifest` at all — no
    /// manifest re-probe, no metadata re-fetch.
    func testCaptionsForTrack_prefersHTTPFetchOverYtDlpFallback() async throws {
        let track = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false,
                                  url: "https://example.com/de.vtt")
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [track],
            content: [track: "WEBVTT yt-dlp fallback\n\n00:00:00.000 --> 00:00:01.000\nwrong"],
            httpContent: [track: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, track: track, captionFetcher: captionFetcher)

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.segments.count, 2, "must have used the HTTP-fetched VTT, not the yt-dlp fallback")
        XCTAssertEqual(transcript.captionsAuto, false)
        XCTAssertEqual(captionFetcher.httpFetchCalls, [track])
        XCTAssertEqual(captionFetcher.fetchCalls, [], "yt-dlp fallback must not run when the HTTP fetch succeeds")
        XCTAssertEqual(captionFetcher.listManifestCalls, [], "no manifest re-probe for an already-known track")
    }

    /// When the track has no `url` (or the HTTP fetch misses), the yt-dlp
    /// `fetchTrack` fallback must still produce a transcript.
    func testCaptionsForTrack_fallsBackToYtDlpWhenNoHTTPURL() async throws {
        let track = Self.manualEN // no `url` scripted
        let captionFetcher = FakeCaptionFetcher(
            videoURL: Self.videoURL, tracks: [track], content: [track: Self.fixtureVTT])

        let result = try await YouTubeTranscriptService.captions(
            forVideoURL: Self.videoURL, track: track, captionFetcher: captionFetcher)

        let transcript = try XCTUnwrap(result)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(captionFetcher.fetchCalls, [
            FakeCaptionFetcher.FetchCall(videoURL: Self.videoURL, track: track),
        ])
    }

    func testCaptionsForTrack_playlistURL_throws() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [Self.manualEN])
        let playlistURL = "https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvw"

        do {
            _ = try await YouTubeTranscriptService.captions(
                forVideoURL: playlistURL, track: Self.manualEN, captionFetcher: captionFetcher)
            XCTFail("expected notAVideoURL to be thrown")
        } catch YouTubeTranscriptError.notAVideoURL(let url) {
            XCTAssertEqual(url, playlistURL)
        }
    }

    // MARK: - listCaptionTracks(forVideoURL:) surfaces the manifest

    func testListCaptionTracks_returnsManifest() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [Self.manualEN, Self.autoDE])

        let tracks = try await YouTubeTranscriptService.listCaptionTracks(
            forVideoURL: Self.videoURL, captionFetcher: captionFetcher)

        XCTAssertEqual(tracks, [Self.manualEN, Self.autoDE])
    }

    func testListCaptionTracks_playlistURL_throws() async throws {
        let captionFetcher = FakeCaptionFetcher(videoURL: Self.videoURL, tracks: [Self.manualEN])
        let playlistURL = "https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvw"

        do {
            _ = try await YouTubeTranscriptService.listCaptionTracks(
                forVideoURL: playlistURL, captionFetcher: captionFetcher)
            XCTFail("expected notAVideoURL to be thrown")
        } catch YouTubeTranscriptError.notAVideoURL(let url) {
            XCTAssertEqual(url, playlistURL)
        }
    }
}
