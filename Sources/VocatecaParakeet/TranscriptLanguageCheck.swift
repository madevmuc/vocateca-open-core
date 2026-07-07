import Foundation
import NaturalLanguage

/// Post-hoc verification that a transcript is plausibly in the expected language.
/// Deliberately LENIENT: code-switched (German + English terms) and short texts
/// must not falsely trigger a Whisper re-run. We only reject a clear mismatch.
enum TranscriptLanguageCheck {
    /// Minimum characters before we trust the recognizer at all.
    static let minChars = 40
    /// The expected language must be at least this probable to pass.
    static let minExpectedProbability = 0.15

    static func looksLike(_ expected: String, text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count >= minChars else { return true }   // too little signal → lenient pass
        guard let base = expectedBase(expected) else { return true }
        let rec = NLLanguageRecognizer()
        rec.processString(stripped)
        let hyps = rec.languageHypotheses(withMaximum: 5)
        let p = hyps[NLLanguage(rawValue: base)] ?? 0
        // Pass if the expected language has *any meaningful* share — lenient by
        // design so bilingual episodes don't ping-pong to Whisper.
        return p >= minExpectedProbability
    }

    static func expectedBase(_ bcp47: String) -> String? {
        let b = bcp47.split(separator: "-").first.map { $0.lowercased() }
        return (b?.isEmpty == false) ? b : nil
    }
}
