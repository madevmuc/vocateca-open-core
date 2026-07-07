import Foundation

// MARK: - TranscriptionEngine

/// The user's transcription-engine preference (persisted in
/// `Settings.transcriptionEngine`). `.auto` defers to hardware; the explicit
/// choices force an engine.
public enum TranscriptionEngine: String, Sendable, Equatable, Codable, CaseIterable {
    /// Pick automatically by hardware (see ``EngineSelector``).
    case auto
    /// Always WhisperKit (CoreML/ANE) — the universal baseline.
    case whisper
    /// Always Qwen3-ASR (MLX/GPU) — higher accuracy, heavier, capable Macs only.
    case qwen
    /// Always Parakeet-TDT (FluidAudio/CoreML-ANE) — fast, Apple Silicon only.
    case parakeet
}

/// The concrete engine actually used to transcribe — the resolved result of a
/// ``TranscriptionEngine`` preference against the machine's capability.
public enum ResolvedEngine: String, Sendable, Equatable {
    case whisper
    case qwen
    case parakeet
}

// MARK: - EngineSelector

/// **Pure** resolution of a ``TranscriptionEngine`` preference to a concrete
/// ``ResolvedEngine`` given the machine's capability. No `sysctl`/IO — all inputs
/// are passed in, so this is fully unit-testable over a hardware/settings matrix.
///
/// `.auto` default: Parakeet-TDT on any Apple Silicon chip tier (fast, CoreML/ANE),
/// Whisper on Intel (Parakeet/FluidAudio is Apple-Silicon only). Explicit `.qwen`
/// is honoured even on weak hardware (the Settings UI warns; the runtime still
/// falls back to Whisper only if the model genuinely fails to load — handled at
/// the wiring layer, not here). `autoQualifiesForQwen` below documents the
/// retired auto-Qwen gate (Apple Silicon Pro/Max/Ultra, ≥ 24 GB); `.auto` no
/// longer calls it, but it's kept for its own tests.
public enum EngineSelector {

    /// Whether this Mac clears the automatic Qwen gate.
    public static func autoQualifiesForQwen(chipTier: Hardware.ChipTier, unifiedMemoryGB: Int) -> Bool {
        let strongChip = (chipTier == .pro || chipTier == .max || chipTier == .ultra)
        return strongChip && unifiedMemoryGB >= 24
    }

    /// Whether an **explicit** `.qwen` choice on this Mac should be gated behind a
    /// hard confirmation (M11). An explicit override bypasses the automatic
    /// ``autoQualifiesForQwen`` gate, so on a machine that does NOT clear that gate
    /// (< 24 GB unified memory, or a base/Intel chip) the 1.7B MLX model can swap
    /// the machine to death — the known 16 GB failure. Pure (no IO) so the UI and
    /// the queue-wiring layer share one decision. Returns `false` for any
    /// non-`.qwen` preference (nothing to confirm).
    public static func explicitQwenNeedsConfirmation(
        preference: TranscriptionEngine,
        chipTier: Hardware.ChipTier,
        unifiedMemoryGB: Int
    ) -> Bool {
        guard preference == .qwen else { return false }
        return !autoQualifiesForQwen(chipTier: chipTier, unifiedMemoryGB: unifiedMemoryGB)
    }

    /// Resolves the preferred engine against hardware facts.
    ///
    /// `.auto` defaults to Parakeet on Apple Silicon (fast, CoreML/ANE) and falls
    /// back to Whisper on Intel, where Parakeet (FluidAudio) is unavailable.
    /// Explicit `.parakeet` follows the same Apple-Silicon requirement; explicit
    /// `.whisper`/`.qwen` are honoured unconditionally (see `autoQualifiesForQwen`
    /// doc above for the retired auto-Qwen gate, still used by its own tests).
    public static func resolve(
        preference: TranscriptionEngine,
        chipTier: Hardware.ChipTier,
        unifiedMemoryGB: Int
    ) -> ResolvedEngine {
        switch preference {
        case .whisper:
            return .whisper
        case .qwen:
            return .qwen   // explicit override; UI warns on weak HW, wiring falls back on load failure
        case .parakeet:
            return chipTier != .intel ? .parakeet : .whisper   // CoreML/ANE needs Apple Silicon
        case .auto:
            return chipTier != .intel ? .parakeet : .whisper   // EU/US default = Parakeet on Apple Silicon
        }
    }

    /// Convenience: resolve against the *live* hardware of this Mac.
    public static func resolveLive(preference: TranscriptionEngine) -> ResolvedEngine {
        resolve(preference: preference,
                chipTier: Hardware.chipTier(),
                unifiedMemoryGB: Hardware.unifiedMemoryGB())
    }

    /// **Pure** resolution of the user's **backup** engine (Package C).
    ///
    /// Resolves the `fallbackPreference` to a concrete ``ResolvedEngine`` the same
    /// way ``resolve(preference:chipTier:unifiedMemoryGB:)`` does the primary — so
    /// hardware capability applies to the backup too (an explicit Parakeet backup
    /// on Intel becomes Whisper). Returns `nil` when the resolved backup is the
    /// **same concrete engine** as the resolved primary: there is no distinct
    /// fallback, so the wiring layer must not build a pointless self-fallback (a
    /// transcriber that "falls back" to itself). The caller decides what a `nil`
    /// means for its stack — e.g. keep the universal Whisper baseline as the
    /// safety net for a primary that can fail to load.
    ///
    /// No IO — both the UI and the queue-wiring layer share one decision.
    public static func resolveFallback(
        primaryPreference: TranscriptionEngine,
        fallbackPreference: TranscriptionEngine,
        chipTier: Hardware.ChipTier,
        unifiedMemoryGB: Int
    ) -> ResolvedEngine? {
        let primary = resolve(preference: primaryPreference,
                              chipTier: chipTier, unifiedMemoryGB: unifiedMemoryGB)
        let fallback = resolve(preference: fallbackPreference,
                               chipTier: chipTier, unifiedMemoryGB: unifiedMemoryGB)
        return fallback == primary ? nil : fallback
    }

    /// Convenience: resolve the backup against the *live* hardware of this Mac.
    public static func resolveFallbackLive(
        primaryPreference: TranscriptionEngine,
        fallbackPreference: TranscriptionEngine
    ) -> ResolvedEngine? {
        resolveFallback(primaryPreference: primaryPreference,
                        fallbackPreference: fallbackPreference,
                        chipTier: Hardware.chipTier(),
                        unifiedMemoryGB: Hardware.unifiedMemoryGB())
    }
}
