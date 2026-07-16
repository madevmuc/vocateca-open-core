import XCTest
@testable import VocatecaCore

/// Regression: the audio download must always hand yt-dlp an explicit
/// `--ffmpeg-location` so it never depends on the (Homebrew-less) PATH a
/// GUI-launched macOS app inherits — the cause of "ffprobe and ffmpeg not
/// found" despite `brew install ffmpeg` (2026-07-16).
final class YtDlpAudioHookArgsTests: XCTestCase {

    func testAudioArgsIncludeFfmpegLocationWhenDirKnown() {
        let args = YtDlpAudioHook.buildAudioArgs(
            outTemplate: "/tmp/show/ep.%(ext)s",
            ffmpegDir: "/opt/homebrew/bin",
            wantMeta: false,
            urlString: "https://example.com/v"
        )
        guard let idx = args.firstIndex(of: "--ffmpeg-location") else {
            return XCTFail("--ffmpeg-location missing: \(args)")
        }
        XCTAssertEqual(args[safe: idx + 1], "/opt/homebrew/bin")
        // Still extracts audio + keeps the hardened config-ignoring prefix.
        XCTAssertTrue(args.contains("--extract-audio"))
        XCTAssertTrue(args.contains("--ignore-config"))
        // The URL stays terminal, after the `--` separator.
        XCTAssertEqual(args.last, "https://example.com/v")
        XCTAssertEqual(args[args.count - 2], "--")
    }

    func testAudioArgsOmitFfmpegLocationWhenDirNil() {
        let args = YtDlpAudioHook.buildAudioArgs(
            outTemplate: "/tmp/show/ep.%(ext)s",
            ffmpegDir: nil,
            wantMeta: false,
            urlString: "https://example.com/v"
        )
        XCTAssertFalse(args.contains("--ffmpeg-location"))
    }

    func testAudioArgsWriteInfoJSONWhenMetaWanted() {
        let args = YtDlpAudioHook.buildAudioArgs(
            outTemplate: "/tmp/show/ep.%(ext)s",
            ffmpegDir: "/opt/homebrew/bin",
            wantMeta: true,
            urlString: "https://example.com/v"
        )
        XCTAssertTrue(args.contains("--write-info-json"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
