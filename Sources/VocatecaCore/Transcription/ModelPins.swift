import Foundation
import CryptoKit

// MARK: - ModelPins (M-3 groundwork)
//
// Security hardening (2026-07-05): all three transcription engines fetch
// multi-GB model bundles resolving a mutable upstream ref with no revision
// pin and no checksum — see docs/audits/audit-security-report-2026-07-05.md
// finding M-3. Full pinning needs upstream seams that don't exist yet:
//
//   - speech-swift (Qwen): `Qwen3ASRModel.fromPretrained(modelId:progressHandler:)`
//     has no `revision:` parameter — verified in
//     `.build/checkouts/speech-swift/Sources/Qwen3ASR/Qwen3ASR.swift`.
//     TODO(M-3, upstream): request a `revision:`/commit-hash parameter on
//     speech-swift's `fromPretrained` APIs (Qwen3ASRModel + Qwen3ForcedAligner).
//   - FluidAudio (Parakeet): `AsrModels.downloadAndLoad(version:)` resolves a
//     hardcoded `resolve/main/` path with no override.
//     TODO(M-3, upstream): request a pinnable `resolve/<revision>` option (or
//     vendor the pin) in FluidAudio's `AsrModels` download path.
//   - WhisperKit: `WhisperKitConfig(model:...,download: true)` fetches the
//     latest snapshot of the named model repo with no revision override
//     exposed either — same upstream-seam gap.
//
// This file is the APP-SIDE part that doesn't need those seams: a single
// source of truth for which repo (+ eventual revision/hash) each engine's
// model variant is supposed to resolve to, so the day a `revision:` parameter
// lands upstream, wiring it through is a one-line change per engine, and the
// CLI health check (`vocateca-cli/main.swift`) has something honest to check
// against right now instead of a hardcoded `ok`.
//
// MARK: - Checksum manifest (P.5, 2026-07-23)
//
// `revision` above is blocked on upstream seams that don't exist yet. A
// SHA256 checksum is a *different*, app-side-only mitigation for the same
// underlying risk (a model silently changing under the user): we already
// control the on-disk file after download, so we can hash it ourselves
// regardless of whether upstream exposes a revision pin.
//
// `Pin.sha256` records the expected digest once we've deliberately pinned
// one; `Pin.verify(fileURL:)` checks a downloaded file against it. The
// manifest starts **completely empty** — every `sha256` below is `nil` — so
// `verify` always takes its "nothing pinned, skip" path and this feature
// changes NO behavior until someone deliberately records a real checksum
// (never guessed/invented; see call sites in `ModelProvisioner` and
// `QwenProvisioning`). Only Qwen's provisioning path can act on a checksum
// today, because it downloads to a single known file
// (`model.safetensors`) we already inspect for size (M11); Parakeet
// (FluidAudio) and WhisperKit hand back loaded model objects / multi-file
// directories with no single canonical file exposed to hash against, so
// their gates are honest no-ops until upstream exposes more — same shape of
// limitation as the `revision` TODOs above.
public enum ModelPins {

    /// One pinned (or not-yet-pinnable) model reference.
    public struct Pin: Sendable, Equatable {
        /// The upstream repo id (HuggingFace namespace/repo or FluidAudio's
        /// internal model-set identifier).
        public let repo: String
        /// Expected revision/commit — `nil` until the upstream seam exists
        /// (see file-level TODOs above). When `nil`, ``isPinned`` is `false`
        /// and the CLI health check reports "unpinned" rather than claiming
        /// safety it cannot verify.
        public let revision: String?
        /// Expected SHA256 checksum (hex, case-insensitive) of the model's
        /// primary on-disk file — `nil` until deliberately recorded (see the
        /// "Checksum manifest" note above). This is the empty-by-default
        /// manifest: every entry in this file has `sha256 == nil` today, so
        /// ``verify(fileURL:)`` always takes its no-op "skip" path.
        public let sha256: String?

        public init(repo: String, revision: String? = nil, sha256: String? = nil) {
            self.repo = repo
            self.revision = revision
            self.sha256 = sha256
        }

        /// `true` only when a concrete revision is recorded. Currently always
        /// `false` for every engine (upstream-blocked — see TODOs above);
        /// flipping this to `true` for an engine is the signal that its
        /// upstream seam has landed and the pin is real.
        public var isPinned: Bool { revision != nil }

        /// Verifies `fileURL` against ``sha256``.
        ///
        /// - `sha256 == nil` (the manifest hasn't pinned a checksum for this
        ///   model — true for every entry today) → `true`: nothing to check,
        ///   so this is a pure no-op and provisioning behaves exactly as it
        ///   did before this feature existed.
        /// - `sha256` set and the file is unreadable (missing, permissions,
        ///   etc.) → `false`: we can't confirm integrity, so don't trust it.
        /// - `sha256` set and the digest doesn't match → `false`: the file on
        ///   disk isn't the one we pinned.
        /// - `sha256` set and the digest matches → `true`.
        public func verify(fileURL: URL) -> Bool {
            guard let expected = sha256 else { return true }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return false
            }
            let hex = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return hex.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    /// Qwen3-ASR model variants, keyed by the same Settings variant key
    /// `QwenTranscriber.modelId(forVariant:)` uses.
    public static let qwen: [String: Pin] = [
        "1.7B-8bit": Pin(repo: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"),
        "1.7B-4bit": Pin(repo: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"),
        "0.6B-8bit": Pin(repo: "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"),
    ]

    /// The Qwen3 forced-aligner model (separate download, used only when
    /// `forcedAlign` is enabled).
    public static let qwenAligner = Pin(repo: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit")

    /// Parakeet-TDT (FluidAudio) — no per-variant selection today (always v3).
    public static let parakeet = Pin(repo: "FluidAudio/parakeet-tdt (v3)")

    /// WhisperKit — the model name is user-selected at runtime
    /// (`WhisperKitTranscriber.modelName`), so there is no single fixed repo
    /// to pin here; each concrete model name resolves against WhisperKit's
    /// own HF-hosted CoreML repo (`argmaxinc/whisperkit-coreml`).
    public static let whisperRepo = "argmaxinc/whisperkit-coreml"

    /// WhisperKit checksum entries, keyed by `WhisperKitTranscriber.modelName`.
    /// Empty by default: model names are open-ended/user-selected (see
    /// ``whisperRepo`` above), so an entry only ever gets added here for a
    /// specific name someone has deliberately decided to pin — none exist yet.
    public static let whisper: [String: Pin] = [:]

    /// Whether ANY engine has a real (non-`nil`) revision pin recorded yet.
    /// Drives the CLI's `model_hash` health row (I-3): today this is always
    /// `false`, so the row honestly reports "unpinned" instead of the
    /// previous hardcoded `ok: true, "no pin yet (first use)"`.
    public static var anyPinned: Bool {
        qwen.values.contains { $0.isPinned } || qwenAligner.isPinned || parakeet.isPinned
    }
}
