import Foundation

// MARK: - Hardware

/// Hardware capability helpers used to size automatic concurrency.
public enum Hardware {

    /// Number of performance cores on this Mac (Apple Silicon `hw.perflevel0`),
    /// falling back to the logical CPU count when the key is unavailable.
    public static func performanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Automatic transcribe concurrency derived from the performance/load level
    /// and the machine's performance-core count. Mirrors the `parallel` value in
    /// the Python `core/load.py` profiles: 1 for quiet/balanced, and 2 on the
    /// "full" level when there are ≥ 8 performance cores.
    public static func autoTranscribeConcurrency(loadLevel: String, perfCores: Int) -> Int {
        let p = max(1, perfCores)
        switch loadLevel {
        case "full": return p >= 8 ? 2 : 1
        default:     return 1   // quiet, balanced
        }
    }

    // MARK: - Capability (Qwen engine gate)

    /// Apple-Silicon performance tier, parsed from `machdep.cpu.brand_string`.
    /// `.intel` marks a non-Apple-Silicon Mac (never eligible for the GPU engine).
    public enum ChipTier: String, Sendable, Equatable {
        case intel
        case base   // "Apple M#" with no suffix
        case pro    // "Apple M#Pro"
        case max    // "Apple M#Max"
        case ultra  // "Apple M#Ultra"
    }

    /// Reads `machdep.cpu.brand_string` (e.g. "Apple M2 Pro", "Intel(R) Core…").
    /// Returns "" when unavailable.
    public static func cpuBrandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "" }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// **Pure** parser: CPU brand string → ``ChipTier``. Unit-tested against
    /// fixture strings (no `sysctl` dependency). Order matters — "ultra"/"max"/
    /// "pro" are checked most-specific first.
    public static func chipTier(fromBrand brand: String) -> ChipTier {
        let s = brand.lowercased()
        guard s.contains("apple") else { return .intel }
        if s.contains("ultra") { return .ultra }
        if s.contains("max")   { return .max }
        if s.contains("pro")   { return .pro }
        return .base
    }

    /// This Mac's chip tier (live `sysctl`).
    public static func chipTier() -> ChipTier { chipTier(fromBrand: cpuBrandString()) }

    /// Whether this Mac is Apple Silicon.
    public static func isAppleSilicon() -> Bool { chipTier() != .intel }

    /// Total unified/system memory in whole GB (`hw.memsize`), rounded down.
    /// Returns 0 when unavailable.
    public static func unifiedMemoryGB() -> Int {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0, bytes > 0 else { return 0 }
        return Int(bytes / (1024 * 1024 * 1024))
    }
}
