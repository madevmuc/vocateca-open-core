import XCTest
@testable import VocatecaCore

/// `Settings.deleteMp3AfterTranscribe` default flip (2026-07-21): audio is
/// deleted immediately after a successful transcription by default, to stop the
/// unbounded MP3 buildup that a `false` fresh-install default allowed (37.6 GB
/// found and manually deleted). Class name is unique so
/// `swift test --filter DeleteMp3AfterTranscribeSettingTests` selects exactly
/// these.
final class DeleteMp3AfterTranscribeSettingTests: XCTestCase {

    func testDefaultIsTrue() {
        XCTAssertEqual(Settings.defaultDeleteMp3AfterTranscribe, true)
    }

    func testDefaultConstructedSettingsDeletesAudio() {
        XCTAssertEqual(Settings().deleteMp3AfterTranscribe, true)
    }

    /// An empty YAML document must yield the compiled-in default (`true`) —
    /// mirrors `DiarizationSettingTests.testEmptyYAMLYieldsDefaultTrue`.
    func testEmptyYAMLYieldsDefaultTrue() throws {
        let s = try SettingsStore.decode(from: "{}")
        XCTAssertEqual(s.deleteMp3AfterTranscribe, true)
    }

    /// An explicit `false` overrides the (true) default — proves the decode
    /// path actually reads the key rather than always returning the default.
    func testExplicitFalseDecodes() throws {
        let yaml = """
        delete_mp3_after_transcribe: false
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.deleteMp3AfterTranscribe, false)
    }
}
