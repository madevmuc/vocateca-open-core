import Foundation

// MARK: - ProvisioningState

/// The state of a transcription-model download.
public enum ProvisioningState: Sendable, Equatable {
    /// Not started (or cancelled — safe to retry).
    case idle
    /// Download in progress; `fraction` is 0…1.
    case downloading(fraction: Double)
    /// The model is present on disk and ready to transcribe.
    case ready
    /// Download failed; `String` is a human-readable reason.
    case failed(String)
}

// MARK: - ModelProvisioner

/// Orchestrates provisioning (background download) of a transcription engine's
/// model. Pure and dependency-injected — the "is it cached?" check and the actual
/// download are supplied as closures — so it is fully unit-testable with fakes and
/// carries no engine/MLX dependency (the real Qwen downloader lives in
/// `VocatecaQwen`; Whisper's is WhisperKit's own on-first-use fetch).
///
/// A `ProvisioningCoordinator` (UI) drives this at first-run / engine-change and
/// bridges progress → Notifications; episodes sit `pending` until `.ready`.
public struct ModelProvisioner: Sendable {

    /// A download operation that reports 0…1 progress and throws on failure.
    public typealias DownloadOperation =
        @Sendable (_ onProgress: @escaping @Sendable (Double) -> Void) async throws -> Void

    /// User-facing engine/model label, e.g. "Qwen3-ASR 1.7B".
    public let engineLabel: String
    /// Approximate download size in GB (for the consent prompt); 0 if unknown.
    public let sizeGB: Double

    private let isCached: @Sendable () -> Bool
    private let download: DownloadOperation

    public init(
        engineLabel: String,
        sizeGB: Double,
        isCached: @escaping @Sendable () -> Bool,
        download: @escaping DownloadOperation
    ) {
        self.engineLabel = engineLabel
        self.sizeGB = sizeGB
        self.isCached = isCached
        self.download = download
    }

    /// Whether the model is already on disk (no download needed).
    public var isReady: Bool { isCached() }

    /// Runs provisioning to a terminal state, streaming 0…1 fractions via
    /// `onProgress`. No-op returning `.ready` when already cached. Cancellation
    /// returns `.idle` (retryable) and is never reported as a failure.
    public func provision(
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> ProvisioningState {
        if isCached() {
            Log.debug("Model already cached", component: "Provisioning",
                      context: [("engine", engineLabel)])
            onProgress(1.0)
            return .ready
        }
        Log.info("Model provisioning started", component: "Provisioning",
                 context: [("engine", engineLabel), ("sizeGB", String(format: "%.1f", sizeGB))])
        // Log download progress at 25% milestones (thread-safe across the
        // @Sendable progress callback).
        let bucket = ProgressBucket()
        let label = engineLabel
        do {
            try await download { frac in
                let clamped = max(0, min(1, frac))
                if bucket.advance(to: clamped) {
                    Log.debug("Model download progress", component: "Provisioning",
                              context: [("engine", label), ("pct", "\(Int(clamped * 100))")])
                }
                onProgress(clamped)
            }
            Log.info("Model ready", component: "Provisioning",
                     context: [("engine", engineLabel)])
            return .ready
        } catch is CancellationError {
            Log.warn("Model provisioning cancelled", component: "Provisioning",
                     context: [("engine", engineLabel)])
            return .idle
        } catch {
            // Surface the underlying error verbatim — never a bare "error 0".
            Log.error("Model provisioning failed", component: "Provisioning",
                      context: [("engine", engineLabel), ("error", "\(error)")])
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - ProgressBucket

/// Thread-safe 25%-milestone tracker so progress logging fires at most once per
/// quarter even when the download callback is invoked from arbitrary threads.
private final class ProgressBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    /// Returns `true` the first time `frac` crosses into a new 25% bucket.
    func advance(to frac: Double) -> Bool {
        let b = Int(frac * 4)
        return lock.withLock {
            if b > last { last = b; return true }
            return false
        }
    }
}
