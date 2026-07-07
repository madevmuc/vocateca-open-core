import Foundation

// MARK: - TranscriptionContext

/// Per-episode conditioning threaded into a `Transcriber` call.
///
/// Carries what a single transcription pass should know about *this* episode:
/// a free-text `prompt` (biases WhisperKit's decoder via
/// `DecodingOptions.promptTokens`), a `glossary` of metadata-known proper nouns
/// (used by engines that support prompt biasing; ignored by the rest, which
/// rely on post-ASR `TranscriptGlossaryCorrector`), and a `language` hint.
///
/// `nil` (the default threaded by the legacy overloads) means "no per-episode
/// context" — engines behave exactly as before this type existed.
///
/// `Sendable` so it can cross the isolation boundary into a transcriber actor.
public struct TranscriptionContext: Sendable, Equatable {
    /// Free-text prompt shown to the decoder to bias spelling/style
    /// (e.g. a per-show Whisper prompt). `nil` when unset.
    public var prompt: String?
    /// Proper-noun candidates for this episode (brand/person names from title,
    /// description, show, author, prompt). Chunk 3 populates this with
    /// `EpisodeGlossary.terms.map(\.text)`.
    public var glossary: [String]
    /// BCP-47 language hint (e.g. `"de"`), or `nil` to let the engine detect.
    public var language: String?

    public init(prompt: String? = nil,
                glossary: [String] = [],
                language: String? = nil) {
        self.prompt = prompt
        self.glossary = glossary
        self.language = language
    }
}
