import Foundation
import VocatecaCore
import Qwen3ASR

// MARK: - QwenProvisioning

/// Bridges the Qwen3-ASR model download to Core's engine-agnostic
/// ``ModelProvisioner``: it knows the on-disk cache layout (for the "already
/// downloaded?" check) and drives the real download via `fromPretrained`.
public enum QwenProvisioning {

    /// speech-swift caches models under `~/Library/Caches/qwen3-speech/models/<modelId>`.
    static var cacheRoot: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("qwen3-speech/models", isDirectory: true)
    }

    /// The on-disk cache directory for a model id.
    static func cacheDir(modelId: String) -> URL {
        cacheRoot.appendingPathComponent(modelId, isDirectory: true)
    }

    /// A safetensors weights file smaller than this is a truncated/aborted
    /// download, not a real model (the smallest Qwen3-ASR bundle is ~0.7 GB).
    /// Well below any real weight file, comfortably above any HTML error page or
    /// partial header a black-holed download might leave behind. (M11)
    static let minWeightsBytes: Int64 = 64 * 1024 * 1024   // 64 MB

    /// Whether the model's weights are already on disk **and look intact** (M11).
    ///
    /// The previous check was pure `fileExists(model.safetensors)`, so an aborted
    /// first download that left a 0-byte or truncated `model.safetensors` read as
    /// "cached" → the real load later failed with a cryptic MLX error and never
    /// self-healed (the file "exists", so nothing re-downloads). Now we also
    /// require the weights file to be at least ``minWeightsBytes`` so a partial
    /// download is treated as *not cached* (and gets purged + re-fetched).
    public static func isCached(modelId: String) -> Bool {
        let weights = cacheDir(modelId: modelId).appendingPathComponent("model.safetensors")
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: weights.path)[.size] as? Int64 else {
            return false   // missing
        }
        return size >= minWeightsBytes
    }

    /// Deletes a partial/corrupt cache directory for `modelId` so the next load
    /// re-downloads cleanly (M11). Called before a download/load when the cache
    /// exists on disk but fails the integrity check — an aborted first download
    /// otherwise leaves a truncated `model.safetensors` that "exists" forever and
    /// makes every subsequent transcribe fail with a cryptic MLX load error.
    /// No-op (returns `false`) when the directory is absent or already intact.
    ///
    /// - Returns: `true` when a corrupt cache was found and removed.
    @discardableResult
    public static func purgeIfCorrupt(modelId: String) -> Bool {
        let dir = cacheDir(modelId: modelId)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // Nothing on disk → nothing to purge.
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Intact → keep it (this is the warm-cache fast path).
        if isCached(modelId: modelId) { return false }
        // Present but incomplete → purge so the next attempt re-downloads.
        let existingSize = (try? fm.attributesOfItem(
            atPath: dir.appendingPathComponent("model.safetensors").path)[.size] as? Int64) ?? 0
        do {
            try fm.removeItem(at: dir)
            Log.warn("Qwen: purged partial/corrupt model cache before load",
                     component: "QwenProvisioning",
                     context: [("modelId", modelId),
                               ("weightsBytes", "\(existingSize)"),
                               ("minBytes", "\(minWeightsBytes)")])
            return true
        } catch {
            Log.error("Qwen: failed to purge corrupt model cache",
                      component: "QwenProvisioning",
                      context: [("modelId", modelId), ("error", "\(error)")])
            return false
        }
    }

    /// Approximate download size (GB) per variant — for the consent prompt.
    public static func approxSizeGB(modelId: String) -> Double {
        let s = modelId.lowercased()
        if s.contains("1.7b") && s.contains("4bit") { return 1.0 }
        if s.contains("1.7b")                       { return 1.8 }   // 8-bit
        if s.contains("0.6b")                       { return 0.7 }
        return 1.8
    }

    /// Downloads (and warms) the model via `Qwen3ASRModel.fromPretrained`,
    /// reporting 0…1 progress. The loaded model is discarded; the cached files
    /// persist for the real transcribe.
    public static func download(
        modelId: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // M11: clear any partial/corrupt cache first so a re-provision after an
        // aborted download actually re-fetches rather than resuming onto a
        // truncated file.
        purgeIfCorrupt(modelId: modelId)
        _ = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: { frac, _ in onProgress(frac) }
        )
    }

    /// A Core ``ModelProvisioner`` configured for the given Qwen model id.
    public static func provisioner(modelId: String) -> ModelProvisioner {
        ModelProvisioner(
            engineLabel: "Qwen3-ASR \(QwenTranscriber.shortTag(for: modelId))",
            sizeGB: approxSizeGB(modelId: modelId),
            isCached: { isCached(modelId: modelId) },
            download: { onProgress in try await download(modelId: modelId, onProgress: onProgress) }
        )
    }
}
