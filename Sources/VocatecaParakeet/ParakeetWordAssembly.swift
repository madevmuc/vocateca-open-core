import Foundation
import FluidAudio

/// Reconstructs word-level timings from Parakeet's per-token output.
///
/// FluidAudio's `AsrManager` exposes `ASRResult.tokenTimings: [TokenTiming]?`,
/// but the only word-assembly helper in the package (`VocabularyRescorer
/// .buildWordTimings(from:)`) is `internal` on an unrelated CTC-rescoring
/// type and unreachable across the module boundary (verified in Task 1). So
/// `VocatecaParakeet` reimplements the same SentencePiece convention itself:
/// a token whose string begins with `▁` (U+2581 LOWER ONE EIGHTH BLOCK, the
/// standard SentencePiece word-boundary marker) starts a new word; tokens
/// without it continue the current word. This mirrors FluidAudio's own
/// internal `isWordBoundary`/`stripWordBoundaryPrefix` helpers
/// (`VocabularyRescorer+Utilities.swift`), which also treat a leading plain
/// space " " as a boundary — included here for parity even though Parakeet's
/// v3 vocab uses `▁` exclusively.
///
/// Kept as plain `(text, start, end)` tuples (no FluidAudio types leak out)
/// so `ParakeetCueGrouping` — and any future consumer — stays dependency-free.
enum ParakeetWordAssembly {

    /// SentencePiece word-boundary marker (U+2581 LOWER ONE EIGHTH BLOCK).
    private static let wordBoundaryMarker: Character = "\u{2581}"

    /// Builds words from raw token timings. Any angle-bracketed special token
    /// (`<blank>`, `<pad>`, and defensively `<unk>`/`<sos>`/`<eos>` or any other
    /// `<…>` control token) plus empty strings are skipped, so no special token
    /// ever leaks into word text. The very first real token always starts a word,
    /// even if it lacks a boundary marker (defensive: some decoder paths may emit
    /// an unmarked leading piece).
    static func words(from tokenTimings: [TokenTiming]) -> [(text: String, start: Double, end: Double)] {
        var result: [(text: String, start: Double, end: Double)] = []

        var currentPieces: [String] = []
        var currentStart: Double = 0
        var currentEnd: Double = 0

        func flush() {
            guard !currentPieces.isEmpty else { return }
            let text = currentPieces.joined()
            if !text.isEmpty {
                result.append((text: text, start: currentStart, end: currentEnd))
            }
            currentPieces.removeAll()
        }

        for timing in tokenTimings {
            let token = timing.token
            // Skip empty strings and any `<…>` special/control token so none leaks
            // into word text (covers <blank>/<pad> plus <unk>/<sos>/<eos>/…).
            guard !token.isEmpty, !(token.hasPrefix("<") && token.hasSuffix(">")) else { continue }

            let startsNewWord = isWordBoundary(token) || currentPieces.isEmpty
            if startsNewWord && !currentPieces.isEmpty {
                flush()
            }

            let piece = stripWordBoundaryPrefix(token)
            if startsNewWord {
                currentStart = timing.startTime
            }
            if !piece.isEmpty {
                currentPieces.append(piece)
            }
            currentEnd = timing.endTime
        }
        flush()

        return result
    }

    /// A token starts a new word if it begins with the SentencePiece `▁`
    /// marker or (defensively) a plain space.
    private static func isWordBoundary(_ token: String) -> Bool {
        token.first == wordBoundaryMarker || token.first == " "
    }

    /// Strips a leading `▁` or space boundary marker, if present.
    private static func stripWordBoundaryPrefix(_ token: String) -> String {
        guard let first = token.first, first == wordBoundaryMarker || first == " " else {
            return token
        }
        return String(token.dropFirst())
    }
}
