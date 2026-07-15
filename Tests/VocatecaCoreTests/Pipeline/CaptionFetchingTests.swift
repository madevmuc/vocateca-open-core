import XCTest
@testable import VocatecaCore

// MARK: - CaptionFetchingTests
//
// Protocol seam over the manifest-driven pieces of the concrete
// YtDlpCaptionFetcher enum, so YouTubeTranscriptService.captions(forVideoURL:)
// can be unit-tested with a fake instead of hitting the network.

final class CaptionFetchingTests: XCTestCase {

    /// `YtDlpCaptionFetching.listManifest` must forward straight to the
    /// static `YtDlpCaptionFetcher.listManifest`, not reimplement any logic.
    /// `"not-a-url"` is rejected by `URLSafety.safeURL` before any network
    /// access, so this stays a same-process unit test — no
    /// `VOCATECA_RUN_NETWORK_TESTS` gate needed.
    func testYtDlpCaptionFetchingListManifestForwardsToStaticFetcher() async {
        let sut = YtDlpCaptionFetching()
        let result = await sut.listManifest(videoURL: "not-a-url")
        XCTAssertNil(result.meta, "an unsafe/unresolvable URL must be rejected without a live network call")
        XCTAssertEqual(result.tracks, [])
    }

    /// `YtDlpCaptionFetching.listTracks` must forward straight to the static
    /// `YtDlpCaptionFetcher.listTracks`, not reimplement any logic.
    func testYtDlpCaptionFetchingListTracksForwardsToStaticFetcher() async {
        let sut = YtDlpCaptionFetching()
        let result = await sut.listTracks(videoURL: "not-a-url")
        XCTAssertEqual(result, [], "an unsafe/unresolvable URL must be rejected without a live network call")
    }

    /// `YtDlpCaptionFetching.fetchTrackViaHTTP` must forward straight to the
    /// static `YtDlpCaptionFetcher.fetchTrackViaHTTP`. A track with no `url`
    /// is rejected before any network access, so this stays a same-process
    /// unit test.
    func testYtDlpCaptionFetchingFetchTrackViaHTTPForwardsToStaticFetcher() async {
        let sut = YtDlpCaptionFetching()
        let track = CaptionTrack(languageCode: "en", displayName: "English", isAuto: false)
        let result = await sut.fetchTrackViaHTTP(track)
        XCTAssertNil(result, "a track with no url must be rejected without a live network call")
    }

    /// `YtDlpCaptionFetching.fetchTrack` must forward straight to the static
    /// `YtDlpCaptionFetcher.fetchTrack`, same rejection path as above.
    func testYtDlpCaptionFetchingFetchTrackForwardsToStaticFetcher() async {
        let sut = YtDlpCaptionFetching()
        let track = CaptionTrack(languageCode: "en", displayName: "English", isAuto: false)
        let result = await sut.fetchTrack(videoURL: "not-a-url", track: track)
        XCTAssertNil(result, "an unsafe/unresolvable URL must be rejected without a live network call")
    }

    // MARK: - FakeCaptionFetcher self-test

    func testFakeCaptionFetcherListsScriptedManifestPerVideo() async {
        let track = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false)
        let meta = YouTubeVideoMeta(videoID: "x", title: "Title", channelID: "UC1", channelHandle: "@h")
        let fake = FakeCaptionFetcher(videoURL: "https://youtu.be/x", tracks: [track], meta: meta)

        let manifest = await fake.listManifest(videoURL: "https://youtu.be/x")
        let emptyManifest = await fake.listManifest(videoURL: "https://youtu.be/other")

        XCTAssertEqual(manifest.tracks, [track])
        XCTAssertEqual(manifest.meta, meta)
        XCTAssertNil(emptyManifest.meta, "a videoURL absent from the script must return nil meta")
        XCTAssertEqual(emptyManifest.tracks, [], "a videoURL absent from the script must return an empty manifest")
        XCTAssertEqual(fake.listManifestCalls, ["https://youtu.be/x", "https://youtu.be/other"])
    }

    func testFakeCaptionFetcherListsScriptedTracksPerVideo() async {
        let track = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false)
        let fake = FakeCaptionFetcher(videoURL: "https://youtu.be/x", tracks: [track])

        let tracks = await fake.listTracks(videoURL: "https://youtu.be/x")
        let empty = await fake.listTracks(videoURL: "https://youtu.be/other")

        XCTAssertEqual(tracks, [track])
        XCTAssertEqual(empty, [], "a videoURL absent from the script must return an empty manifest")
        XCTAssertEqual(fake.listCalls, ["https://youtu.be/x", "https://youtu.be/other"])
    }

    func testFakeCaptionFetcherFetchesScriptedContentPerExactTrack() async {
        let manual = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false)
        let auto = CaptionTrack(languageCode: "de", displayName: "German (auto)", isAuto: true)
        let fake = FakeCaptionFetcher(
            videoURL: "https://youtu.be/x",
            tracks: [manual, auto],
            content: [manual: "WEBVTT manual"])

        let manualContent = await fake.fetchTrack(videoURL: "https://youtu.be/x", track: manual)
        let autoContent = await fake.fetchTrack(videoURL: "https://youtu.be/x", track: auto)

        XCTAssertEqual(manualContent, "WEBVTT manual")
        XCTAssertNil(autoContent, "a track absent from the content script must return nil")
        XCTAssertEqual(fake.fetchCalls, [
            .init(videoURL: "https://youtu.be/x", track: manual),
            .init(videoURL: "https://youtu.be/x", track: auto),
        ])
    }

    func testFakeCaptionFetcherFetchesScriptedHTTPContentPerExactTrackURL() async {
        let withURL = CaptionTrack(languageCode: "de", displayName: "German", isAuto: false,
                                    url: "https://example.com/de.vtt")
        let withoutURL = CaptionTrack(languageCode: "en", displayName: "English", isAuto: false)
        let fake = FakeCaptionFetcher(
            videoURL: "https://youtu.be/x",
            tracks: [withURL, withoutURL],
            httpContent: [withURL: "WEBVTT http"])

        let httpContent = await fake.fetchTrackViaHTTP(withURL)
        let missing = await fake.fetchTrackViaHTTP(withoutURL)

        XCTAssertEqual(httpContent, "WEBVTT http")
        XCTAssertNil(missing, "a track with no url (or an unscripted url) must return nil")
        XCTAssertEqual(fake.httpFetchCalls, [withURL, withoutURL])
    }
}
