import Foundation

// MARK: - WorkerConfig

/// Configuration that governs how the ``QueueWorker`` schedules transcription work.
///
/// `WorkerConfig` is a pure Core type — it has no dependency on `VocatecaUI` or
/// `AppKit`. The UI layer (`QueueController`) builds a `WorkerConfig` from the
/// current `AppMode` and `Settings` and passes it to `QueueRunner.applyConfig(_:)`.
///
/// ## Concurrency mapping
///
/// | Mode        | Concurrency setting | Effective concurrency         | Task QoS         |
/// |-------------|---------------------|-------------------------------|-----------------|
/// | Background  | Auto                | `autoTranscribeConcurrency` at "balanced" = 1 | `.utility`       |
/// | Background  | Manual (n)          | n (user's explicit choice)    | `.utility`       |
/// | Power       | Auto                | `autoTranscribeConcurrency` at "full"          | `.userInitiated` |
/// | Power       | Manual (n)          | n (user's explicit choice)    | `.userInitiated` |
///
/// When concurrency is Auto (`concurrencyAuto == true`), the mode drives the
/// load-level that feeds into `Hardware.autoTranscribeConcurrency`. When the user
/// has set a manual override, we honour it for concurrency but still apply the
/// QoS difference so Background remains gentle on the CPU.
public struct WorkerConfig: Sendable, Equatable {

    /// Maximum number of episodes to transcribe in parallel.
    public let concurrencyLimit: Int

    /// Task quality-of-service for transcription work.
    ///
    /// - `.utility`       — Background mode: low CPU scheduling priority, thermally gentle.
    /// - `.userInitiated` — Power mode: foreground priority, maximum throughput.
    public let taskQoS: QualityOfService

    // MARK: - Init

    public init(concurrencyLimit: Int, taskQoS: QualityOfService) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.taskQoS = taskQoS
    }

    // MARK: - Factory

    /// Derives the correct `WorkerConfig` from the app mode and settings.
    ///
    /// - Parameters:
    ///   - isPowerMode:      `true` when `AppMode == .power`.
    ///   - concurrencyAuto:  `true` when the user hasn't pinned a manual concurrency value.
    ///   - manualConcurrency: The user's manual override (ignored when `concurrencyAuto`).
    ///   - perfCores:         Number of performance cores on this Mac.
    public static func from(
        isPowerMode: Bool,
        concurrencyAuto: Bool,
        manualConcurrency: Int,
        perfCores: Int
    ) -> WorkerConfig {
        // Power mode → `.userInitiated`; background mode → `.utility`.
        //
        // We deliberately do NOT use `.background` here: at `.background` QoS macOS
        // treats network transfers as *discretionary* and can throttle/defer them
        // to a crawl, so a user who just hit Retry sees a "stuck" download. `.utility`
        // is still low-priority and battery-gentle but keeps downloads progressing,
        // and matches this type's documented mode→QoS table.
        let qos: QualityOfService = isPowerMode ? .userInitiated : .utility

        let concurrency: Int
        if concurrencyAuto {
            // Auto: map mode → load-level → effective count.
            // Background → "balanced" (always 1), Power → "full" (2 on ≥8-core Macs).
            let loadLevel = isPowerMode ? "full" : "balanced"
            concurrency = Hardware.autoTranscribeConcurrency(
                loadLevel: loadLevel,
                perfCores: max(1, perfCores)
            )
        } else {
            // Manual override: user's explicit concurrency value.
            concurrency = max(1, manualConcurrency)
        }

        return WorkerConfig(concurrencyLimit: concurrency, taskQoS: qos)
    }
}
