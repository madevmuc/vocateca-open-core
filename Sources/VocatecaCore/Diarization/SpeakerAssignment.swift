import Foundation

// MARK: - SpeakerAssignment

/// Pure overlap-based merge of ASR segments with diarization output.
///
/// No FluidAudio, no I/O — just interval math — so it can run in the
/// pipeline right after transcription/correction and be unit-tested with
/// plain fixtures.
public enum SpeakerAssignment {

    /// Assigns each `TranscriptionSegment` the `speaker` of the
    /// `SpeakerSegment` it overlaps the most in time.
    ///
    /// - Ties (equal maximum overlap) resolve to the **lower** speaker index,
    ///   independent of the order `speakers` is given in.
    /// - A transcript segment with **no** overlapping speaker segment (or an
    ///   empty `speakers` array) keeps `speaker == nil`.
    ///
    /// - Parameters:
    ///   - segments: ASR segments to tag (typically post-correction).
    ///   - speakers: Diarization spans, in any order.
    /// - Returns: A new array, same order/count as `segments`, each with
    ///            `speaker` set per the rule above.
    public static func assign(_ segments: [TranscriptionSegment], speakers: [SpeakerSegment]) -> [TranscriptionSegment] {
        guard !speakers.isEmpty else { return segments }

        return segments.map { segment in
            var best: SpeakerSegment?
            var bestOverlap = 0.0

            for candidate in speakers {
                let overlap = overlapDuration(segment: segment, speaker: candidate)
                guard overlap > 0 else { continue }

                if overlap > bestOverlap || (overlap == bestOverlap && candidate.speaker < (best?.speaker ?? Int.max)) {
                    bestOverlap = overlap
                    best = candidate
                }
            }

            var tagged = segment
            tagged.speaker = best?.speaker
            return tagged
        }
    }

    /// Seconds of overlap between a transcript segment `[segment.start, segment.end)`
    /// and a speaker span `[speaker.start, speaker.end)`. Zero (never negative)
    /// when the intervals don't intersect.
    private static func overlapDuration(segment: TranscriptionSegment, speaker: SpeakerSegment) -> Double {
        let start = max(segment.start, speaker.start)
        let end = min(segment.end, speaker.end)
        return max(0, end - start)
    }
}
