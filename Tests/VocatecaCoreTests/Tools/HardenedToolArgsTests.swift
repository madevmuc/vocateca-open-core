import XCTest
@testable import VocatecaCore

/// Tests for the L-3 hardened argument prefixes (`YtDlp.hardenedBaseArgs` /
/// `GalleryDL.hardenedBaseArgs`).
///
/// Full call-site coverage (every yt-dlp/gallery-dl `Process` invocation
/// actually prepends these) is verified structurally via
/// `rg 'ignore-config' swift/Sources` per the security-hardening brief's
/// Verify step — most call sites (`YtDlpAudioHook`, `MediaURLResolver`,
/// `YouTubeResolver`) build their argument arrays inline rather than through
/// a pure/testable function, so there is no seam to unit-test the FULL args
/// array for those beyond `RealGalleryDLClient.buildArguments`
/// (see `OCRExtensionTests.testBuildArgumentsAlwaysIncludesIgnoreConfig`).
final class HardenedToolArgsTests: XCTestCase {

    func testYtDlpHardenedArgsContainsIgnoreConfigAndNoPlugins() {
        XCTAssertEqual(YtDlp.hardenedBaseArgs, ["--ignore-config", "--no-plugins"])
    }

    func testGalleryDLHardenedArgsContainsIgnoreConfig() {
        XCTAssertEqual(GalleryDL.hardenedBaseArgs, ["--ignore-config"])
    }

    /// The hardened flags must always be FIRST — a hostile config discovered
    /// before `--ignore-config` is parsed defeats the point.
    func testHardenedArgsPrependCorrectlyToAnExampleArgList() {
        let exampleArgs = YtDlp.hardenedBaseArgs + ["--continue", "--no-playlist"]
        XCTAssertEqual(exampleArgs.first, "--ignore-config")
        XCTAssertEqual(exampleArgs[1], "--no-plugins")
    }
}
