import Foundation
import WhisperKit
import CoreML         // MLComputeUnits (compute-unit selection)
import AVFoundation   // audio duration for progress estimation

// MARK: - Sendable wrapper

/// Swift 6 requires values crossing isolation boundaries to be `Sendable`.
/// `WhisperKit` is an `open class` without a `Sendable` conformance, so we
/// box it in a `@unchecked Sendable` wrapper and restrict all access to the
/// owning actor — preserving the safety guarantee at the design level.
private final class WhisperKitBox: @unchecked Sendable {
    let whisperKit: WhisperKit
    init(_ whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }
}

/// Thread-safe throttle so the per-token WhisperKit callback logs at most once
/// per new 30 s window. Without this a long transcription is completely silent
/// between "model loaded" and completion, which reads in the diagnostic log as
/// if the job died — see `transcribe(_:language:progress:)`.
private final class WindowLogThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWindow = -1
    /// Returns `true` the first time each distinct `window` is seen.
    func shouldLog(window: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard window != lastWindow else { return false }
        lastWindow = window
        return true
    }
}

// MARK: - WhisperKitTranscriber

/// A `Transcriber` backed by WhisperKit's CoreML pipeline.
///
/// Declared as an `actor` so the loaded `WhisperKit` instance is isolated:
/// the first `transcribe` call triggers a one-time lazy model download and
/// load; subsequent calls reuse the already-loaded instance without re-downloading.
///
/// Usage:
/// ```swift
/// let t = WhisperKitTranscriber()
/// let result = try await t.transcribe(audioURL: url, language: nil)
/// print(result.text)
/// ```
public actor WhisperKitTranscriber: Transcriber {

    // MARK: - Configuration

    private let modelName: String

    // MARK: - Lazy state

    /// Populated on the first `transcribe` call; reused thereafter.
    private var kitBox: WhisperKitBox?

    // MARK: - Initialisation

    /// Creates a transcriber that will use `model` on first use.
    ///
    /// - Parameter model: WhisperKit model identifier, e.g. `"openai_whisper-tiny"`.
    ///   The model is downloaded from the default HuggingFace repo
    ///   (`argmaxinc/whisperkit-coreml`) on first use and cached by the system.
    public init(model: String = "openai_whisper-tiny") {
        self.modelName = model
    }

    /// Maps a user-facing Whisper model name (as stored in `Settings.whisperModel`
    /// / shown in the picker, e.g. `"large-v3-turbo"`) to the WhisperKit model
    /// identifier WhisperKit expects (`"openai_whisper-large-v3-turbo"`).
    ///
    /// - Empty input falls back to the default (`large-v3-turbo`).
    /// - An already-qualified id (`openai_whisper-…`) is passed through unchanged,
    ///   so this is idempotent and safe if a full id is ever stored.
    public static func whisperKitModelID(from settingsName: String) -> String {
        var name = settingsName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "large-v3-turbo" }
        // WhisperKit expects a SHORT variant name (e.g. "large-v3_turbo") and
        // forms the repo folder `openai_whisper-<name>` itself. Prepending
        // `openai_whisper-` here made it search `*openai*openai_whisper-…/*` and
        // fail with `modelsUnavailable`. Its turbo folders also use an UNDERSCORE
        // separator — the real folder is `openai_whisper-large-v3_turbo`, not
        // `…-large-v3-turbo`. Strip any prefix and normalise the turbo suffix.
        if name.hasPrefix("openai_whisper-") {
            name = String(name.dropFirst("openai_whisper-".count))
        }
        if name.hasSuffix("-turbo") {
            name = String(name.dropLast("-turbo".count)) + "_turbo"
        }
        return name
    }

    // MARK: - Transcriber

    /// `true` once `loadedBox()` has cached a `WhisperKitBox` — i.e. the model
    /// has already been downloaded (if needed) and loaded. A cheap actor-state
    /// read; never triggers I/O.
    public var isWarm: Bool { kitBox != nil }

    public func transcribe(audioURL: URL, language: String?) async throws -> VocatecaCore.TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: { _ in })
    }

    // NOTE: the parameter MUST be spelled `progress: ProgressReporter` to match
    // the protocol requirement EXACTLY. Writing the expanded
    // `@escaping @Sendable (Double) -> Void` made this method a non-witness
    // overload, so `any Transcriber.transcribe(…progress:)` dispatched to the
    // protocol's DEFAULT extension instead (which emits 0.0 once and forwards to
    // the no-progress 2-arg method) — the per-window callback ran but its
    // `progress` was a no-op, freezing the UI bar at the download-done fraction.
    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: @escaping ProgressReporter
    ) async throws -> VocatecaCore.TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: progress)
    }

    /// Context-aware entry point: builds `DecodingOptions.promptTokens` from the
    /// per-episode prompt + glossary (via `promptTokens(for:tokenizer:)`) so the
    /// decoder is biased toward known proper-noun spellings. When `context` is
    /// nil / empty, `promptTokens` stays nil and decoding is byte-for-byte
    /// identical to the previous behaviour. Spell the parameters verbatim so this
    /// is the protocol witness (see the progress-overload note above).
    public func transcribe(
        audioURL: URL,
        language: String?,
        context: TranscriptionContext?,
        progress: @escaping ProgressReporter
    ) async throws -> VocatecaCore.TranscriptionResult {
        let box = try await loadedBox()
        let whisperKit = box.whisperKit

        // Turn the (previously dead) per-episode prompt into WhisperKit prompt
        // tokens. `tokenizer` is populated once the model is loaded above; if it
        // is somehow nil, we simply omit the prompt (no crash, no downgrade).
        let promptTokens = Self.promptTokens(
            for: context,
            tokenizer: whisperKit.tokenizer.map(WhisperTokenizerAdapter.init))
        if let promptTokens, let promptString = Self.promptString(from: context) {
            Log.info("WhisperKit: biasing decode with episode prompt",
                     component: "WhisperKit",
                     context: [("promptChars", String(promptString.count)),
                               ("promptTokens", String(promptTokens.count))])
        }

        // Audio duration → turn WhisperKit's per-window callback into a real 0…1
        // fraction so the bar advances during a long transcription (WhisperKit
        // reports no overall progress). Use AVURLAsset (reliable for .mp3 — unlike
        // AVAudioFile, which returns length 0 for many compressed files and left
        // the bar frozen at 50 %).
        let durationSec: Double
        do {
            let asset = AVURLAsset(url: audioURL)
            let secs = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            durationSec = secs.isFinite && secs > 0 ? secs : 0
        }

        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            // `usePrefillPrompt` must stay true so promptTokens are prepended to
            // the forced prefill (task/language) tokens rather than replacing
            // them; WhisperKit's TextDecoder prepends `startOfPreviousToken` and
            // filters special tokens from promptTokens itself.
            usePrefillPrompt: true,
            // Skip special tokens so segment text is clean.
            skipSpecialTokens: true,
            // nil when no episode prompt → identical to prior behaviour.
            promptTokens: promptTokens
        )

        // Heartbeat logging: WhisperKit runs the whole transcription inside one
        // `await` with no built-in progress log, so a long job is silent for
        // minutes and looks aborted in Help → Diagnostic Logs. Log the start,
        // one line per new 30 s window (with the estimated fraction), and the
        // completion so the log proves the job is alive and advancing.
        Log.info("WhisperKit: transcription starting",
                 component: "WhisperKit",
                 context: [("audio", audioURL.lastPathComponent),
                           ("durationSec", durationSec > 0 ? String(format: "%.0f", durationSec) : "unknown"),
                           ("model", modelName)])
        let transcribeStart = Date()
        let throttle = WindowLogThrottle()

        // Call WhisperKit's `transcribe(audioPath:decodeOptions:)` which returns
        // the library's own `[TranscriptionResult]`. Type inference resolves this
        // without needing to name `WhisperKit.TranscriptionResult` explicitly.
        let wkResults = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodeOptions,
            // Per-window callback: (1) report progress from the 30s window index
            // vs the audio duration, and (2) cooperative cancellation — returning
            // `false` aborts CoreML inference at the next segment boundary (e.g.
            // on a transcription-timeout `group.cancelAll()`).
            // Signature: TranscriptionCallback = ((TranscriptionProgress) -> Bool?)?
            callback: { (p: TranscriptionProgress) -> Bool? in
                // WhisperKit advances in ~30 s windows; `windowId` is the current
                // one. With a known duration → an accurate fraction; without it →
                // an asymptotic curve that still moves so the bar is never frozen.
                let w = Double(p.windowId)
                let frac = durationSec > 0
                    ? (w * 30.0) / durationSec
                    : 1.0 - exp(-w / 15.0)
                let clamped = min(max(frac, 0), 0.98)
                progress(clamped)
                // One log line the first time each window is reached — proves
                // the decode is advancing (vs stuck re-decoding one window).
                if throttle.shouldLog(window: p.windowId) {
                    Log.debug("WhisperKit: transcribing",
                              component: "WhisperKit",
                              context: [("window", String(p.windowId)),
                                        ("percent", String(format: "%.0f", clamped * 100)),
                                        ("audioSec", String(format: "%.0f", w * 30.0))])
                }
                return !Task.isCancelled
            }
        )

        // Map WhisperKit segments → our domain types inline to avoid needing
        // to declare `WhisperKit.TranscriptionResult` in a named parameter type.
        var domainSegments: [VocatecaCore.TranscriptionSegment] = []
        for wkResult in wkResults {
            for seg in wkResult.segments {
                let segText = seg.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !segText.isEmpty else { continue }
                domainSegments.append(
                    VocatecaCore.TranscriptionSegment(
                        start: Double(seg.start),
                        end: Double(seg.end),
                        text: segText,
                        noSpeechProb: Double(seg.noSpeechProb),
                        avgLogprob: Double(seg.avgLogprob)
                    )
                )
            }
        }

        let fullText = domainSegments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Language is stored per-window; take the first non-empty value.
        let detectedLanguage: String? = wkResults
            .map { $0.language }
            .first(where: { !$0.isEmpty })

        Log.info("WhisperKit: transcription complete",
                 component: "WhisperKit",
                 context: [("audio", audioURL.lastPathComponent),
                           ("segments", String(domainSegments.count)),
                           ("chars", String(fullText.count)),
                           ("language", detectedLanguage ?? "?"),
                           ("elapsedSec", String(format: "%.1f", Date().timeIntervalSince(transcribeStart)))])

        return VocatecaCore.TranscriptionResult(
            text: fullText,
            segments: domainSegments,
            language: detectedLanguage,
            origin: .whisper(model: modelName)
        )
    }

    // MARK: - Private helpers

    /// Returns the already-loaded box or downloads + loads the model now.
    private func loadedBox() async throws -> WhisperKitBox {
        if let existing = kitBox {
            return existing
        }

        Log.info("WhisperKit: loading model (first load compiles it for the GPU — a few seconds)",
                 component: "WhisperKit",
                 context: [("model", modelName),
                           ("timeoutSec", String(format: "%.0f", modelLoadTimeoutSeconds))])
        let loadStart = Date()
        do {
            let modelName = self.modelName   // capture for the @Sendable closure
            // H6: bound the lazy download+load. WhisperKit's `WhisperKit(config)`
            // has no timeout of its own; a stalled first download (network
            // black-hole) would otherwise never return and pin the episode in
            // `transcribing` forever. On timeout `withTimeout` throws
            // `TimeoutError`, which we let propagate un-wrapped so the Pipeline
            // classifies it as TRANSIENT (retryable) rather than a permanent
            // model-load failure. `WhisperKit` is non-Sendable, so it is boxed in
            // the existing `WhisperKitBox` (@unchecked Sendable) to return out of
            // the timeout race — created here and only ever used on this actor.
            let box = try await withTimeout(seconds: modelLoadTimeoutSeconds) {
                let config = WhisperKitConfig(
                    model: modelName,
                    // Run entirely on the GPU (Metal). WhisperKit's default routes the
                    // audio encoder + text decoder through the Apple Neural Engine,
                    // which forces a slow one-time CoreML→ANE compile (minutes,
                    // low-CPU) that looks like a hang at 50%. `.cpuAndGPU` skips that —
                    // the model loads in seconds and inference runs on the GPU.
                    computeOptions: ModelComputeOptions(
                        melCompute: .cpuAndGPU,
                        audioEncoderCompute: .cpuAndGPU,
                        textDecoderCompute: .cpuAndGPU
                    ),
                    verbose: false,
                    // `download: true` triggers download + load in one pass.
                    download: true
                )
                return WhisperKitBox(try await WhisperKit(config))
            }
            kitBox = box
            // M-3 groundwork: `download: true` fetches the latest snapshot of
            // `modelName`'s HF repo (`ModelPins.whisperRepo`) with no revision
            // override exposed by WhisperKitConfig — see the upstream-blocked
            // TODO in `ModelPins.swift`.
            Log.info("WhisperKit: model loaded",
                     component: "WhisperKit",
                     context: [("model", modelName), ("repo", ModelPins.whisperRepo),
                               ("revisionPin", "none (M-3 upstream-blocked)"),
                               ("seconds", String(format: "%.1f", Date().timeIntervalSince(loadStart)))])
            return box
        } catch let timeout as TimeoutError {
            // H6: transient — let the pipeline requeue. Do NOT wrap in
            // `modelLoadFailed` (which the pipeline treats as a one-retry-cap
            // engine error); a bare `TimeoutError` is routed to `.transient`.
            Log.error("WhisperKit: model load TIMED OUT — requeue (transient)",
                      component: "WhisperKit",
                      context: [("model", modelName),
                                ("elapsedSec", String(format: "%.0f", Date().timeIntervalSince(loadStart))),
                                ("timeoutSec", String(format: "%.0f", timeout.seconds))])
            throw timeout
        } catch {
            // Wrap so callers can catch a domain-level error and distinguish
            // model-unavailable (offline) from other failures.
            throw WhisperKitTranscriberError.modelLoadFailed(modelName, underlying: error)
        }
    }
}

// MARK: - Prompt tokenization seam

/// Narrow seam over the one WhisperKit tokenizer method we need
/// (`func encode(text:) -> [Int]`). Declaring our own protocol lets the
/// prompt-token helper be unit-tested with a fake — no CoreML model download —
/// while WhisperKit's real `WhisperTokenizer` satisfies it for free (its
/// signature matches exactly; conformance added below).
public protocol WhisperPromptTokenizing {
    func encode(text: String) -> [Int]
}

/// Adapter bridging WhisperKit's `WhisperTokenizer` (a protocol, so it can't be
/// retroactively conformed to another protocol directly) to our
/// `WhisperPromptTokenizing` seam. Used at the call site to pass
/// `whisperKit.tokenizer` into the pure `promptTokens(for:tokenizer:)` helper.
private struct WhisperTokenizerAdapter: WhisperPromptTokenizing {
    let tokenizer: WhisperTokenizer
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
}

// MARK: - Pure prompt helpers (unit-tested)

public extension WhisperKitTranscriber {
    /// Builds the free-text prompt string biased into the decoder, or `nil` when
    /// there is nothing to bias with. Combines the episode `prompt` and the
    /// comma-joined `glossary`, dropping empty/whitespace-only parts:
    ///   `[context.prompt, context.glossary.joined(", ")]` compacted, space-joined.
    /// Pure — no model access — so it is fully unit-testable.
    static func promptString(from context: TranscriptionContext?) -> String? {
        guard let context else { return nil }
        let glossaryJoined = context.glossary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let parts: [String?] = [context.prompt, glossaryJoined.isEmpty ? nil : glossaryJoined]
        let combined = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    /// Encodes the prompt string (see `promptString(from:)`) to WhisperKit
    /// prompt token IDs using the supplied tokenizer, or `nil` when there is no
    /// prompt / the tokenizer is unavailable / it yields no tokens. Guarded so
    /// `DecodingOptions.promptTokens` is set only to a non-empty array.
    /// `tokenizer` is injectable (a fake in tests) so this needs no model.
    static func promptTokens(for context: TranscriptionContext?,
                             tokenizer: WhisperPromptTokenizing?) -> [Int]? {
        guard let promptString = promptString(from: context), let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: promptString)
        return tokens.isEmpty ? nil : tokens
    }
}

// MARK: - Error

public enum WhisperKitTranscriberError: Error, Sendable {
    /// The model could not be loaded — most commonly because the download
    /// requires network access that is unavailable.
    case modelLoadFailed(String, underlying: Error)
}
