import Foundation
import VocatecaCore

/// Groups Parakeet word timings into subtitle-sized `TranscriptionSegment` cues.
/// Mirrors VocatecaQwen's WordCueGrouping rules but on a plain word tuple so it
/// carries no FluidAudio/AudioCommon types.
enum ParakeetCueGrouping {
    static let maxCueSeconds = 5.0
    static let maxCueWords = 14

    static func segments(fromWords words: [(text: String, start: Double, end: Double)]) -> [TranscriptionSegment]? {
        let usable = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = usable.first, let last = usable.last, last.end - first.start > 0.01 else { return nil }

        var segs: [TranscriptionSegment] = []
        var cue: [(text: String, start: Double, end: Double)] = []
        func flush() {
            guard let f = cue.first, let l = cue.last else { return }
            let text = cue.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segs.append(TranscriptionSegment(start: f.start, end: l.end, text: text)) }
            cue.removeAll()
        }
        for w in usable {
            cue.append(w)
            let endsSentence = w.text.range(
                of: "[.!?。！？…]+[\"'”’)\\]]*$", options: .regularExpression
            ) != nil
            let overBudget = (w.end - cue[0].start) >= maxCueSeconds || cue.count >= maxCueWords
            if endsSentence || overBudget { flush() }
        }
        flush()
        return segs.isEmpty ? nil : segs
    }
}
