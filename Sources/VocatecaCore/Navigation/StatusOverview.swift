import Foundation

// MARK: - StatusOverview

/// Pure computation backing the three "Ampel" (traffic-light) status cards on
/// the **Status** screen (Quellen / Werkzeuge / Speicher). No UI, no I/O — the
/// UI layer gathers the raw figures (orphaned-show count, feeds in backoff,
/// tool presence, media bytes vs cap) and feeds them in; this enum turns them
/// into a `Level` (ok / warn / error) per card so the thresholds are testable
/// from `VocatecaCoreTests` without a UI harness (mirrors `StartupTabResolver`).
public enum StatusOverview {

    // MARK: - Level

    /// Health level for a single status card, driving its coloured dot.
    /// Ordered so `max` picks the worst level when combining signals.
    public enum Level: Int, Sendable, Equatable, Comparable, CaseIterable {
        case ok    = 0   // green
        case warn  = 1   // amber
        case error = 2   // red

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Sources card (Quellen)

    /// Feed health: how many subscribed shows are polling cleanly vs. broken.
    ///
    /// A source counts as unhealthy when it is either orphaned (its feed was
    /// lost — surfaced to the Repair tool) or currently in persistent backoff
    /// (`FeedBackoff` paused it after repeated failures). Both are the same
    /// user-facing signal: "this source isn't updating".
    ///
    /// - `error` when any source is unhealthy (there's something to reconnect).
    /// - `ok` otherwise (including the zero-source case: nothing broken).
    ///
    /// - Parameters:
    ///   - totalSources: Total subscribed shows.
    ///   - unhealthySources: Shows that are orphaned OR in backoff (deduplicated
    ///     by the caller).
    public static func sourcesLevel(totalSources: Int, unhealthySources: Int) -> Level {
        unhealthySources > 0 ? .error : .ok
    }

    /// The healthy source count shown as "%lld/%lld ok" (never negative).
    public static func healthySources(totalSources: Int, unhealthySources: Int) -> Int {
        max(0, totalSources - max(0, unhealthySources))
    }

    // MARK: - Tools card (Werkzeuge)

    /// External-tool readiness (ffmpeg / yt-dlp). Both are required for the app
    /// to download and transcode media, so a missing tool is an `error` (the
    /// user must install it before anything works).
    ///
    /// - Parameter missingRequiredTools: Count of required managed tools whose
    ///   managed binary is absent (from `BinaryManager.requiredToolsMissing()`).
    public static func toolsLevel(missingRequiredTools: Int) -> Level {
        missingRequiredTools > 0 ? .error : .ok
    }

    // MARK: - Storage card (Speicher)

    /// Media-folder usage against the configured cap.
    ///
    /// - `ok`    when the cap is disabled (unbounded — nothing to warn about) or
    ///           usage is below the near-full threshold.
    /// - `warn`  when usage is at or above `warnFraction` of the cap (default
    ///           90 %, matching `MediaCapPolicy.isNearFull`) but not yet over.
    /// - `error` when usage is at or above the cap itself (the cap sweep will be
    ///           evicting media).
    ///
    /// - Parameters:
    ///   - usedBytes: Current media-folder size in bytes.
    ///   - capBytes: Cap in bytes (`MediaCapPolicy.capBytes(forGb:)`).
    ///   - capEnabled: Whether the storage cap is turned on.
    ///   - warnFraction: Fraction of the cap at which to warn (default 0.9).
    public static func storageLevel(
        usedBytes: Int64,
        capBytes: Int64,
        capEnabled: Bool,
        warnFraction: Double = 0.9
    ) -> Level {
        guard capEnabled, capBytes > 0 else { return .ok }
        if usedBytes >= capBytes { return .error }
        if Double(usedBytes) >= Double(capBytes) * warnFraction { return .warn }
        return .ok
    }
}
