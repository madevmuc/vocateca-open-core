import Foundation
import VocatecaCore
import AudioCommon

// MARK: - Word → segment cue grouping

/// Groups word-level forced-alignment output (`AlignedWord`, seconds) into
/// subtitle-sized `TranscriptionSegment` cues suitable for `.srt` lines.
///
/// The Qwen3 forced aligner emits one timestamp pair per whitespace word. Raw
/// per-word cues are far too granular for subtitles, so we merge consecutive
/// words into cues that break on either a sentence-ending punctuation mark or a
/// soft time/word budget — whichever comes first.
enum WordCueGrouping {

    /// Max wall-clock span of a single cue before we force a break.
    static let maxCueSeconds: Double = 5.0
    /// Max words in a single cue before we force a break (guards against
    /// run-on speech with no punctuation).
    static let maxCueWords: Int = 14

    /// Builds `TranscriptionSegment`s from aligned words. Returns `nil` when
    /// there is nothing usable (empty input or all-zero timestamps), so the
    /// caller can fall back to a single whole-file segment.
    static func segments(from words: [AlignedWord]) -> [VocatecaCore.TranscriptionSegment]? {
        let usable = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return nil }

        // Guard against a degenerate alignment where every word collapsed to the
        // same timestamp: if the whole span is ~0, the cues would be meaningless.
        let span = Double(usable.last!.endTime) - Double(usable.first!.startTime)
        guard span > 0.01 else { return nil }

        var segments: [VocatecaCore.TranscriptionSegment] = []
        var cueWords: [AlignedWord] = []

        func flush() {
            guard let first = cueWords.first, let last = cueWords.last else { return }
            let text = cueWords.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { cueWords.removeAll(); return }
            let start = Double(first.startTime)
            let end = max(Double(last.endTime), start + 0.001)  // monotonic, non-zero-length
            segments.append(VocatecaCore.TranscriptionSegment(start: start, end: end, text: text))
            cueWords.removeAll()
        }

        for word in usable {
            cueWords.append(word)
            let cueStart = Double(cueWords.first!.startTime)
            let elapsed = Double(word.endTime) - cueStart
            let endsSentence = word.text.range(
                of: "[.!?。！？…]+[\"'”’)\\]]*$", options: .regularExpression
            ) != nil
            if endsSentence || elapsed >= maxCueSeconds || cueWords.count >= maxCueWords {
                flush()
            }
        }
        flush()

        return segments.isEmpty ? nil : segments
    }
}
