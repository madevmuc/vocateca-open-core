import Foundation

// MARK: - NoSpeechVerdict

/// The result of classifying a `TranscriptionResult` for the presence of speech.
public struct NoSpeechVerdict: Sendable, Equatable {
    /// `true` when the detector is confident the audio contains no real speech.
    public let isNoSpeech: Bool
    /// Human-readable explanation when `isNoSpeech == true`, otherwise `nil`.
    public let reason: String?

    public init(isNoSpeech: Bool, reason: String? = nil) {
        self.isNoSpeech = isNoSpeech
        self.reason = reason
    }
}

// MARK: - NoSpeechDetector

/// Cheap, post-transcription heuristic that flags audio which likely contains
/// no real speech (e.g. music, instrumental tracks, silence).
///
/// ## Design goal
/// **Be conservative** — only flag when at least one strong signal holds.
/// A false negative (letting a music transcript through) is far less harmful
/// than a false positive (silently skipping a real episode).
///
/// ## Thresholds
/// | Constant                        | Value | Rationale |
/// |----------------------------------|-------|-----------|
/// | `noSpeechProbThreshold`          | 0.60  | WhisperKit emits >0.5 for music; 0.6 keeps a margin above typical speech segments (0.1–0.4). |
/// | `minDurationForWpmCheck`         | 60 s  | Short clips (<1 min) legitimately have few words; skip WPM check to avoid false positives. |
/// | `lowWpmThreshold`                | 3 wpm | A human speaking at conversational pace ≥ 100 wpm; 3 wpm catches Whisper hallucinating single words over long music. |
/// | `minWordsForRepetitionCheck`     | 30    | Smaller samples produce unreliable unique-word ratios. |
/// | `uniqueWordRatioThreshold`       | 0.20  | <20% unique words = Whisper looping on music (e.g. repeating "the, the, the…"). Normal speech ≥ 0.35. |
public enum NoSpeechDetector {

    // MARK: - Thresholds (named constants)

    /// Mean `noSpeechProb` across segments above this value → flag as no-speech.
    static let noSpeechProbThreshold: Double = 0.60

    /// Minimum audio duration (seconds) required before the words-per-minute check applies.
    /// Short clips have too few samples to give a reliable WPM.
    static let minDurationForWpmCheck: Double = 60.0

    /// Words-per-minute below this value (combined with minimum duration) → flag.
    static let lowWpmThreshold: Double = 3.0

    /// Minimum total word count required before the unique-word ratio check applies.
    static let minWordsForRepetitionCheck: Int = 30

    /// Unique-word ratio below this value (when above `minWordsForRepetitionCheck`) → flag.
    static let uniqueWordRatioThreshold: Double = 0.20

    // MARK: - Public API

    /// Classifies `result` for the presence of real speech.
    ///
    /// - Parameters:
    ///   - result:      The `TranscriptionResult` to inspect.
    ///   - durationSec: Known audio duration in seconds, or `nil` when unavailable.
    ///                  Only needed for the words-per-minute check; all other signals work without it.
    /// - Returns: A ``NoSpeechVerdict`` with `isNoSpeech == true` and a human reason
    ///            string if any strong signal fires; otherwise `.init(isNoSpeech: false)`.
    public static func classify(_ result: TranscriptionResult, durationSec: Double?) -> NoSpeechVerdict {

        // ── Signal 1: empty transcript ─────────────────────────────────────
        let words = result.text
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.isEmpty }
        if words.isEmpty {
            Log.info("NoSpeechDetector: empty text → no-speech",
                     component: "NoSpeech", context: [])
            return NoSpeechVerdict(
                isNoSpeech: true,
                reason: "No speech detected — transcript is empty"
            )
        }

        // ── Signal 2: high mean noSpeechProb ──────────────────────────────
        let probSegments = result.segments.compactMap(\.noSpeechProb)
        if !probSegments.isEmpty {
            let meanProb = probSegments.reduce(0, +) / Double(probSegments.count)
            if meanProb > noSpeechProbThreshold {
                let formatted = String(format: "%.2f", meanProb)
                Log.info("NoSpeechDetector: high noSpeechProb → no-speech",
                         component: "NoSpeech",
                         context: [("meanProb", formatted)])
                return NoSpeechVerdict(
                    isNoSpeech: true,
                    reason: "No speech detected — likely music/instrumental (noSpeechProb \(formatted))"
                )
            }
        }

        // ── Signal 3: very low words-per-minute (long clip only) ──────────
        if let dur = durationSec, dur >= minDurationForWpmCheck {
            let durationMin = dur / 60.0
            let wpm = Double(words.count) / durationMin
            if wpm < lowWpmThreshold {
                let formattedWpm = String(format: "%.1f", wpm)
                Log.info("NoSpeechDetector: low WPM → no-speech",
                         component: "NoSpeech",
                         context: [("wpm", formattedWpm), ("durationSec", "\(Int(dur))")])
                return NoSpeechVerdict(
                    isNoSpeech: true,
                    reason: "No speech detected — very low word rate (\(formattedWpm) wpm)"
                )
            }
        }

        // ── Signal 4: Whisper loop — very low unique-word ratio ────────────
        if words.count >= minWordsForRepetitionCheck {
            let lowercased = words.map { $0.lowercased() }
            let unique = Set(lowercased)
            let ratio = Double(unique.count) / Double(lowercased.count)
            if ratio < uniqueWordRatioThreshold {
                let formattedRatio = String(format: "%.2f", ratio)
                Log.info("NoSpeechDetector: low unique-word ratio → no-speech",
                         component: "NoSpeech",
                         context: [("ratio", formattedRatio), ("words", "\(words.count)")])
                return NoSpeechVerdict(
                    isNoSpeech: true,
                    reason: "No speech detected — Whisper looping (unique-word ratio \(formattedRatio))"
                )
            }
        }

        // ── All signals negative: real speech ─────────────────────────────
        Log.debug("NoSpeechDetector: speech detected — no signal fired",
                  component: "NoSpeech",
                  context: [("words", "\(words.count)")])
        return NoSpeechVerdict(isNoSpeech: false)
    }
}
