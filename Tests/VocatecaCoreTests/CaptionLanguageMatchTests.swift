import XCTest
@testable import VocatecaCore

// MARK: - CaptionLanguageMatchTests
//
// P6/P6-EXT fix — ``CaptionLanguageMatcher/selectTrack(from:desiredLanguage:originalLanguage:)``
// is a pure function: no yt-dlp, no I/O, hand-built ``CaptionTrack`` lists
// only. Covers the exact bidirectional region-mismatch cases from the bug
// report (gPW_mitgosw: metadata "en-US" vs. auto track "en"; 6Q7-FTtDvrI:
// metadata "de" vs. manual track "de-DE") plus exact match, unknown-language
// fallback, and manual-preferred-over-auto.

final class CaptionLanguageMatchTests: XCTestCase {

    // MARK: - en-US desired vs track "en" (auto-track region mismatch, gPW_mitgosw)

    func testDesiredRegionalVariant_matchesBaseLanguageTrack() {
        let tracks = [CaptionTrack(languageCode: "en", displayName: "English", isAuto: true)]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: "en-US", originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "en",
                        "desired 'en-US' must fall back to base-language match against track 'en'")
    }

    // MARK: - de desired vs track "de-DE" (manual-track region mismatch, 6Q7-FTtDvrI)

    func testDesiredBaseLanguage_matchesRegionalTrack() {
        let tracks = [CaptionTrack(languageCode: "de-DE", displayName: "German (Germany)", isAuto: false)]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: "de", originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "de-DE",
                        "desired 'de' must fall back to base-language match against track 'de-DE'")
    }

    // MARK: - exact match

    func testExactMatch_isPreferredOverBaseMatch() {
        let tracks = [
            CaptionTrack(languageCode: "en-GB", displayName: "English (UK)", isAuto: false),
            CaptionTrack(languageCode: "en", displayName: "English", isAuto: false),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: "en", originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "en", "an exact 'en' match must win over the base-matching 'en-GB'")
    }

    // MARK: - unknown desired language -> sensible-default fallback

    func testUnknownDesiredLanguage_fallsBackToSensibleDefault() {
        let tracks = [
            CaptionTrack(languageCode: "ja", displayName: "Japanese", isAuto: true),
            CaptionTrack(languageCode: "fr", displayName: "French", isAuto: false),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: "xx-XX", originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "fr",
                        "an unresolvable desired language must fall back to the first manual track, not nil")
    }

    // MARK: - manual preferred over auto in-language

    func testManualTrack_isPreferredOverAutoInSameLanguage() {
        let tracks = [
            CaptionTrack(languageCode: "en", displayName: "English (auto-generated)", isAuto: true),
            CaptionTrack(languageCode: "en", displayName: "English", isAuto: false),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: "en", originalLanguage: nil)

        XCTAssertEqual(selected?.isAuto, false, "a manual track must be preferred over an auto track in the same language")
    }

    // MARK: - desired nil -> prefers originalLanguage

    func testDesiredNil_prefersOriginalLanguageTrack() {
        let tracks = [
            CaptionTrack(languageCode: "en", displayName: "English", isAuto: false),
            CaptionTrack(languageCode: "de-DE", displayName: "German (Germany)", isAuto: false),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: nil, originalLanguage: "de")

        XCTAssertEqual(selected?.languageCode, "de-DE",
                        "with no explicit desired language, the video's original language must be preferred (base match)")
    }

    // MARK: - desired nil, no originalLanguage -> first manual, else first auto

    func testDesiredAndOriginalNil_fallsBackToFirstManualElseFirstAuto() {
        let manualFirst = [
            CaptionTrack(languageCode: "ja", displayName: "Japanese", isAuto: true),
            CaptionTrack(languageCode: "fr", displayName: "French", isAuto: false),
        ]
        XCTAssertEqual(CaptionLanguageMatcher.selectTrack(
            from: manualFirst, desiredLanguage: nil, originalLanguage: nil)?.languageCode, "fr")

        let autoOnly = [CaptionTrack(languageCode: "ja", displayName: "Japanese", isAuto: true)]
        XCTAssertEqual(CaptionLanguageMatcher.selectTrack(
            from: autoOnly, desiredLanguage: nil, originalLanguage: nil)?.languageCode, "ja")
    }

    // MARK: - empty tracks -> nil

    func testEmptyTracks_returnsNil() {
        XCTAssertNil(CaptionLanguageMatcher.selectTrack(from: [], desiredLanguage: "en", originalLanguage: "en"))
    }

    // MARK: - unknown original + no manual + many auto-translations -> prefers "en", not alphabetically-first "af"
    //
    // Regression test: a video with NO manual subs and unknown metadata
    // language (`%(language)s` empty/"NA" — common for music/older/ASR-only
    // uploads) lists the real ASR track PLUS 100+ machine auto-translations
    // as equal keys. Tier 4 must not pick the alphabetically-earliest
    // auto-translation.

    func testUnknownOriginal_manyAutoTranslations_prefersEnglishOverAlphabeticalFirst() {
        let tracks = [
            CaptionTrack(languageCode: "ab", displayName: "Abkhazian", isAuto: true),
            CaptionTrack(languageCode: "af", displayName: "Afrikaans", isAuto: true),
            CaptionTrack(languageCode: "en", displayName: "English", isAuto: true),
            CaptionTrack(languageCode: "zu", displayName: "Zulu", isAuto: true),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: nil, originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "en",
                        "unknown original language with many auto-translations must prefer 'en', not the alphabetically-first 'af'")
    }

    // MARK: - unknown original + "-orig" source ASR track present -> prefers the orig track

    func testUnknownOriginal_origTrackPresent_prefersOrigTrackOverTranslations() {
        let tracks = [
            CaptionTrack(languageCode: "af", displayName: "Afrikaans", isAuto: true),
            CaptionTrack(languageCode: "en-orig", displayName: "English (original)", isAuto: true),
            CaptionTrack(languageCode: "de", displayName: "German", isAuto: true),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: nil, originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "en-orig",
                        "when a '-orig' source ASR track is present it must win over any translation, including 'en'/'de'")
    }

    // MARK: - unknown original, no en/de, only exotic autos -> deterministic (documents behavior)

    func testUnknownOriginal_noEnglishOrGerman_fallsBackDeterministically() {
        let tracks = [
            CaptionTrack(languageCode: "zu", displayName: "Zulu", isAuto: true),
            CaptionTrack(languageCode: "ab", displayName: "Abkhazian", isAuto: true),
        ]

        let selected = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: nil, originalLanguage: nil)

        XCTAssertEqual(selected?.languageCode, "zu",
                        "with no orig/en/de track available, falls back to the first track in the (already-sorted) list")
    }
}
