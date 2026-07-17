import Foundation

// MARK: - RetentionPolicy

/// Pure decision logic for the maintenance / retention pass. No I/O — the runner
/// applies these decisions against the DB + filesystem. Kept pure so the age-out
/// arithmetic is unit-testable with fixed clocks.
///
/// Wires `Settings.deleteMp3AfterTranscribe` + `mp3RetentionDays` +
/// `eventRetentionDays`.
public enum RetentionPolicy {

    /// Whether the downloaded `.mp3` for an episode should be deleted now to
    /// reclaim disk.
    ///
    /// Rules:
    /// - never touch an episode that has no local file, or that isn't `done`
    ///   (we only reclaim space once a transcript exists);
    /// - if `deleteAfterTranscribe` is on → delete as soon as it's `done`;
    /// - otherwise age out `retentionDays` after `completedAt`
    ///   (`retentionDays <= 0` means keep forever).
    public static func shouldDeleteMp3(
        status: String,
        completedAtISO: String?,
        hasLocalFile: Bool,
        deleteAfterTranscribe: Bool,
        retentionDays: Int,
        nowISO: String
    ) -> Bool {
        guard hasLocalFile else { return false }
        guard status == "done" else { return false }
        if deleteAfterTranscribe { return true }
        guard retentionDays > 0 else { return false }
        guard let completed = FeedBackoff.parseISO8601(completedAtISO ?? ""),
              let now = FeedBackoff.parseISO8601(nowISO) else { return false }
        let ageDays = now.timeIntervalSince(completed) / 86_400.0
        return ageDays >= Double(retentionDays)
    }

    /// The ISO cutoff timestamp for event pruning: rows with `ts < cutoff` are
    /// stale and may be deleted. `nil` when retention is disabled (`<= 0`) or the
    /// clock is unparseable (→ caller prunes nothing).
    public static func eventCutoffISO(nowISO: String, retentionDays: Int) -> String? {
        guard retentionDays > 0, let now = FeedBackoff.parseISO8601(nowISO) else { return nil }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400.0)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: cutoff)
    }

    /// Resolves the effective media-retention policy for one show given its
    /// override and the global settings. Returns `nil` to keep media forever,
    /// `0` to reclaim as soon as the episode is transcribed, or `N>0` days.
    /// See `Show.mediaRetentionOverrideDays` sentinels (`-1`/`0`/`N`).
    public static func effectiveMediaRetentionDays(
        showOverride: Int,
        globalDays: Int,
        globalDeleteAfterTranscribe: Bool
    ) -> Int? {
        if showOverride == 0 { return nil }            // keep forever
        if showOverride > 0 { return showOverride }    // explicit N days
        // showOverride < 0 → follow global.
        if globalDeleteAfterTranscribe { return 0 }
        return globalDays > 0 ? globalDays : nil
    }
}

// MARK: - DiskGuard

/// Pure disk-space guard: decides whether the queue should pause because free
/// space dropped below the configured floor. Wires `Settings.diskGuardEnabled` +
/// `diskGuardMinFreeGb`.
public enum DiskGuard {

    /// GB→bytes uses the decimal (1e9) convention to match how macOS reports free
    /// space in Finder, so the threshold means what the user sees.
    public static func minBytes(forGb gb: Int) -> Int64 { Int64(gb) * 1_000_000_000 }

    /// Pause when the guard is enabled, a positive floor is set, and free space is
    /// below it.
    public static func shouldPause(freeBytes: Int64, minFreeGb: Int, enabled: Bool) -> Bool {
        guard enabled, minFreeGb > 0 else { return false }
        return freeBytes < minBytes(forGb: minFreeGb)
    }

    /// M12: live pre-claim check for the queue worker — measures free space on the
    /// volume containing `path` and applies ``shouldPause(freeBytes:minFreeGb:enabled:)``.
    ///
    /// Wraps the same `attributesOfFileSystem` probe `MaintenanceRunner` uses (with
    /// the same fail-open semantics: a stat error returns `.max` free, so a
    /// measurement failure never *falsely* pauses the queue). Exposed here so the
    /// UI's `QueueController` can build a `@Sendable` closure the worker calls
    /// before every claim, without duplicating the free-space arithmetic.
    public static func shouldPause(
        pathToCheck path: String,
        minFreeGb: Int,
        enabled: Bool,
        fileManager: FileManager = .default
    ) -> Bool {
        guard enabled, minFreeGb > 0 else { return false }
        let free = freeBytes(atPath: path, fileManager: fileManager)
        return shouldPause(freeBytes: free, minFreeGb: minFreeGb, enabled: enabled)
    }

    /// Free bytes on the volume containing `path`. Returns `.max` on failure so a
    /// stat error never falsely trips the disk guard. Mirrors the probe used by
    /// `MaintenanceRunner` (falls back to the parent dir when `path` doesn't exist
    /// yet, e.g. the media dir hasn't been created).
    static func freeBytes(atPath path: String, fileManager: FileManager) -> Int64 {
        let probe = fileManager.fileExists(atPath: path)
            ? path
            : (path as NSString).deletingLastPathComponent
        guard let attrs = try? fileManager.attributesOfFileSystem(forPath: probe),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return .max
        }
        return free
    }
}

// MARK: - DiskThresholds

/// Pure plausibility rule for the two low-disk warning thresholds
/// (`Settings.diskWarnHudGb` / `diskWarnModalGb`) against the pause floor
/// (`Settings.diskGuardMinFreeGb`). No I/O — the Settings view applies the
/// resolution and renders the violations; the escalation itself lives in
/// ``DiskWarningLevel``.
///
/// The three numbers form an escalation ladder measured in free GB, and free
/// space only ever falls through it: the queue pauses first (`pause`), then the
/// HUD appears (`hud`), then the modal (`modal`). That ordering is the whole
/// reason for the rule — a HUD above the pause floor would fire while the queue
/// is still happily working, and a modal above the HUD would skip the gentle
/// step entirely.
public enum DiskThresholds {

    /// Every way the trio can be implausible. Reported per offending field so the
    /// UI can say which number it rejected; the strings themselves live in the UI
    /// layer (Core carries no localisation).
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        /// HUD threshold is zero or negative — a threshold that can never fire.
        case hudNotPositive
        /// HUD threshold sits above the pause floor, so it would warn while the
        /// queue is still running.
        case hudAbovePause
        /// Modal threshold is zero or negative.
        case modalNotPositive
        /// Modal threshold sits above the HUD threshold, so the modal would
        /// arrive before (or instead of) the non-blocking HUD.
        case modalAboveHud
    }

    /// The outcome: the values that MUST be stored (already corrected) plus the
    /// violations to report. `violations.isEmpty` means the input was accepted
    /// unchanged.
    public struct Resolution: Sendable, Equatable {
        public let hudGb: Int
        public let modalGb: Int
        public let violations: [Violation]

        public var isValid: Bool { violations.isEmpty }

        public init(hudGb: Int, modalGb: Int, violations: [Violation]) {
            self.hudGb = hudGb
            self.modalGb = modalGb
            self.violations = violations
        }
    }

    /// The lowest threshold that can ever be valid: every threshold must be > 0,
    /// and thresholds are whole GB. An implausible value is reset to THIS rather
    /// than merely clamped to the neighbouring bound — the combination is
    /// refused, not quietly reinterpreted, and 1 GB is the one value that
    /// satisfies the ladder no matter what the other two say.
    public static let lowestValidGb = 1

    /// Resolves `hudGb`/`modalGb` against the pause floor.
    ///
    /// Valid means `0 < modal <= hud <= pause`. Each field that breaks its
    /// constraint is reported and reset to ``lowestValidGb``.
    ///
    /// Violations are judged against the values as GIVEN, never against a value
    /// this function already corrected. Otherwise resetting an out-of-range `hud`
    /// down to 1 would retroactively make a perfectly reasonable `modal` look
    /// like a second mistake, and the user would be told off for something they
    /// did not do. `modal` still follows a corrected `hud` down — that clamp is a
    /// consequence of the first correction, so it is applied silently and the
    /// returned pair is always itself valid.
    ///
    /// `pauseGb <= 0` means the disk guard imposes no floor (the queue never
    /// pauses for disk), which would make `hud <= pause` unsatisfiable for any
    /// positive `hud`. In that case the ceiling is dropped rather than failing
    /// every input: only `0 < modal <= hud` is enforced.
    public static func resolve(hudGb: Int, modalGb: Int, pauseGb: Int) -> Resolution {
        var violations: [Violation] = []
        var hud = hudGb
        var modal = modalGb

        if hud < lowestValidGb {
            violations.append(.hudNotPositive)
            hud = lowestValidGb
        } else if pauseGb >= lowestValidGb, hud > pauseGb {
            violations.append(.hudAbovePause)
            hud = lowestValidGb
        }

        // `modal > hud` is only the user's mistake when the `hud` they typed was a
        // real threshold to be measured against. A `hud` that merely sits above
        // the pause floor still is one (9 vs 12 is a genuine contradiction); a
        // zero or negative `hud` is not, so nothing can meaningfully exceed it.
        let hudAsGivenIsComparable = hudGb >= lowestValidGb

        if modal < lowestValidGb {
            violations.append(.modalNotPositive)
            modal = lowestValidGb
        } else if hudAsGivenIsComparable, modal > hudGb {
            violations.append(.modalAboveHud)
            modal = lowestValidGb
        } else if modal > hud {
            // Only reachable once `hud` was corrected: silent cascade, not a
            // mistake of the user's.
            modal = lowestValidGb
        }

        return Resolution(hudGb: hud, modalGb: modal, violations: violations)
    }
}

// MARK: - MediaCapPolicy

/// Pure global storage-cap eviction policy: given the current on-disk media
/// files and a cap in bytes, decides which files to delete (oldest `mtime`
/// first) until the total is back under the cap. No I/O — `MaintenanceRunner`
/// applies the decision against the filesystem/DB. Wires
/// `Settings.mediaStorageCapGb` + `mediaStorageCapEnabled`.
// MARK: - DiskSpace

/// Volume free/total space for the disk holding Vocateca's data dir. Used by the
/// media-cap 50%-safety clamp and the Status „Storage" card.
public enum DiskSpace {

    /// Free (available) bytes on the volume holding `Paths.userDataDir()`, or `0`
    /// when the volume can't be probed. Decimal-free raw byte count.
    public static func freeBytes(at url: URL = Paths.userDataDir()) -> Int64 {
        guard
            let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
            let free = vals.volumeAvailableCapacity, free >= 0
        else { return 0 }
        return Int64(free)
    }

    /// Total capacity bytes of the same volume, or `0` when unreadable.
    public static func totalBytes(at url: URL = Paths.userDataDir()) -> Int64 {
        guard
            let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
            let total = vals.volumeTotalCapacity, total >= 0
        else { return 0 }
        return Int64(total)
    }
}

public enum MediaCapPolicy {

    /// One on-disk media file candidate for eviction.
    public struct FileEntry: Sendable, Equatable {
        public let guid: String
        public let path: String
        public let sizeBytes: Int64
        public let mtime: Date

        public init(guid: String, path: String, sizeBytes: Int64, mtime: Date) {
            self.guid = guid
            self.path = path
            self.sizeBytes = sizeBytes
            self.mtime = mtime
        }
    }

    /// Result of an eviction decision: the ordered files to delete (oldest
    /// first) and the total bytes that would be freed.
    public struct Decision: Sendable, Equatable {
        public let toEvict: [FileEntry]
        public let freedBytes: Int64

        public init(toEvict: [FileEntry], freedBytes: Int64) {
            self.toEvict = toEvict
            self.freedBytes = freedBytes
        }
    }

    /// GB→bytes uses the decimal (1e9) convention, consistent with `DiskGuard`.
    public static func capBytes(forGb gb: Int) -> Int64 { Int64(gb) * 1_000_000_000 }

    // MARK: - 50%-of-available safety clamp (2026-07-16)
    //
    // Vocateca must never be *configured* to occupy more than half of the disk
    // space actually available to it, no matter what the user types into the
    // cap field. "Available to Vocateca" = the volume's current free space PLUS
    // the media Vocateca already holds (so the bound is stable: freeing our own
    // media doesn't move the ceiling, which would otherwise cause evict/re-
    // download churn near the limit). The user's configured cap is honoured when
    // it's below this ceiling; above it, the EFFECTIVE cap is the ceiling.

    /// The fraction of Vocateca-addressable disk the media cap may never exceed.
    public static let maxAddressableFraction: Double = 0.5

    /// The largest cap (bytes) allowed given the current free disk and the bytes
    /// Vocateca's media already occupies. `addressable = free + currentMedia`;
    /// the ceiling is `maxAddressableFraction` of that. A non-positive
    /// `freeDiskBytes` (unknown/unreadable) disables the clamp (returns `.max`)
    /// so a failed disk probe can never spuriously shrink the cap to zero.
    public static func maxAllowedCapBytes(freeDiskBytes: Int64, currentMediaBytes: Int64) -> Int64 {
        guard freeDiskBytes > 0 else { return .max }
        let addressable = freeDiskBytes + max(0, currentMediaBytes)
        return Int64(Double(addressable) * maxAddressableFraction)
    }

    /// The EFFECTIVE media cap in bytes: the user's configured cap, clamped so it
    /// never exceeds half of Vocateca-addressable disk. THIS is the value every
    /// enforcement + status surface must use — not the raw `capBytes(forGb:)`.
    public static func effectiveCapBytes(
        configuredGb: Int, freeDiskBytes: Int64, currentMediaBytes: Int64
    ) -> Int64 {
        min(capBytes(forGb: configuredGb),
            maxAllowedCapBytes(freeDiskBytes: freeDiskBytes, currentMediaBytes: currentMediaBytes))
    }

    /// The 50%-ceiling expressed in whole GB (floored) — for the Settings hint
    /// ("limited to N GB — half of your free disk"). Returns `nil` when the disk
    /// probe failed (unknown), so the UI can omit the hint rather than lie.
    public static func maxAllowedCapGb(freeDiskBytes: Int64, currentMediaBytes: Int64) -> Int? {
        guard freeDiskBytes > 0 else { return nil }
        let ceiling = maxAllowedCapBytes(freeDiskBytes: freeDiskBytes, currentMediaBytes: currentMediaBytes)
        return Int(ceiling / 1_000_000_000)
    }

    /// The total size of all entries, in bytes.
    public static func totalBytes(_ entries: [FileEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    /// `true` when the total is at or above `thresholdFraction` of the cap
    /// (e.g. `0.9` for the 90% "near full" warning). Evaluated BEFORE eviction.
    public static func isNearFull(entries: [FileEntry], capBytes: Int64, thresholdFraction: Double = 0.9) -> Bool {
        guard capBytes > 0 else { return false }
        let total = totalBytes(entries)
        return Double(total) >= Double(capBytes) * thresholdFraction
    }

    /// Decides which files to evict, oldest-`mtime`-first, until the remaining
    /// total is `<= capBytes`. Under-cap input returns an empty decision.
    /// Ties in `mtime` are broken by `guid` for a stable, deterministic order.
    public static func decide(entries: [FileEntry], capBytes: Int64) -> Decision {
        guard capBytes >= 0 else { return Decision(toEvict: [], freedBytes: 0) }
        var total = totalBytes(entries)
        guard total > capBytes else { return Decision(toEvict: [], freedBytes: 0) }

        let ordered = entries.sorted { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
            return lhs.guid < rhs.guid
        }

        var toEvict: [FileEntry] = []
        var freed: Int64 = 0
        for entry in ordered {
            guard total > capBytes else { break }
            toEvict.append(entry)
            freed += entry.sizeBytes
            total -= entry.sizeBytes
        }
        return Decision(toEvict: toEvict, freedBytes: freed)
    }
}

// MARK: - LocalDurationGuard

/// Pure guard for over-long local imports. Wires `Settings.localMaxDurationHours`
/// — a runaway multi-hour local file can be flagged/skipped before transcode.
public enum LocalDurationGuard {

    /// `true` when the given media duration exceeds the configured maximum.
    /// `maxHours <= 0` disables the guard (never too long).
    public static func isTooLong(durationSec: Int?, maxHours: Int) -> Bool {
        guard maxHours > 0, let durationSec, durationSec > 0 else { return false }
        return durationSec > maxHours * 3_600
    }
}
