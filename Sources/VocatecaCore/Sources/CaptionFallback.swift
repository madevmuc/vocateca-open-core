import Foundation

// MARK: - CaptionFallback

/// Oracle-locked port of `caption_source_chain` from `core/pipeline.py`.
///
/// Returns the ordered list of transcript sources for a YouTube episode.
///
/// Do NOT change this algorithm without regenerating the golden fixtures and
/// running `swift test --filter OracleYouTubeTests`.
public enum CaptionFallback {

    /// Returns the ordered transcript source chain for a YouTube episode.
    ///
    /// Port of `caption_source_chain(pref, fallback_mode)` from `core/pipeline.py`:
    ///
    /// ```
    /// if pref == "whisper":
    ///     return ["whisper"]
    /// if pref == "auto-captions" or fallback_mode == "manual_auto_whisper":
    ///     return ["manual", "auto", "whisper"]
    /// return ["manual", "whisper"]
    /// ```
    ///
    /// - Parameter pref: Per-show transcript preference
    ///   (`""`, `"captions"`, `"auto-captions"`, or `"whisper"`).
    /// - Parameter fallbackMode: The settings caption-fallback mode
    ///   (`"manual_whisper"` or `"manual_auto_whisper"`; unknown values fall
    ///   back to `"manual_whisper"` behaviour).
    /// - Returns: Ordered list of source identifiers (`"manual"`, `"auto"`, `"whisper"`).
    public static func sourceChain(pref: String, fallbackMode: String) -> [String] {
        if pref == "whisper" {
            return ["whisper"]
        }
        // Legacy per-show pref "auto-captions" always means manual→auto→whisper.
        if pref == "auto-captions" || fallbackMode == "manual_auto_whisper" {
            return ["manual", "auto", "whisper"]
        }
        return ["manual", "whisper"]
    }
}
