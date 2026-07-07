import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - SystemSnapshot (Core — no AppKit / no NSScreen)

/// Collects a hardware + OS snapshot using only Foundation/Darwin APIs.
///
/// The NSScreen / display-resolution parts (which need AppKit) are NOT here —
/// they live in `VocatecaUI.SystemInfo` and are passed in as an optional string
/// via `LogStore.copyPayload(systemInfo:)`.
///
/// This enum is safe to import from any target (Core, CLI, tests) — it has
/// zero AppKit dependency.
public enum SystemSnapshot {

    // MARK: - Public API

    /// Builds the Core portion of the system snapshot:
    /// app/OS versions, hardware model, CPU, memory (total + live VM stats +
    /// resident footprint), thermal/power state, disk, locale, uptime.
    ///
    /// Caller may append a `screenInfo` string (built from NSScreen in the UI
    /// layer) to get a fully self-contained snapshot.
    ///
    /// - Parameter appVersion: The app bundle version string. Pass
    ///   `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` from the UI,
    ///   or `"dev"` when running outside a bundle (CLI / tests).
    /// - Returns: A multi-line, human-readable snapshot string.
    public static func corePart(appVersion: String = "dev") -> String {
        var lines: [String] = []

        // ── App + OS ──────────────────────────────────────────────────────────
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("App:         Vocateca \(appVersion)")
        lines.append("macOS:       \(osVersion)")

        // ── Hardware model ────────────────────────────────────────────────────
        let model = sysctlString("hw.model") ?? "unknown"
        lines.append("Model:       \(model)")

        // ── CPU ───────────────────────────────────────────────────────────────
        let totalCores = ProcessInfo.processInfo.activeProcessorCount
        let perfCores  = Hardware.performanceCoreCount()
        let effCores   = max(0, totalCores - perfCores)
        let arch = _currentArchitecture()
        lines.append("CPU:         \(totalCores) cores total (perf=\(perfCores), eff=\(effCores)) \(arch)")

        // ── Memory: total RAM ─────────────────────────────────────────────────
        let physMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        lines.append("RAM total:   \(physMB) MB")

        // ── Memory: live VM stats via host_statistics64 ───────────────────────
        if let vm = _vmStatistics() {
            // Read the hardware page size via sysctl (avoids the shared-mutable-state
            // concurrency warning from `vm_page_size`). Fallback to 4096 (common value).
            var pageSizeRaw: Int = 0
            var pageSizeLen = MemoryLayout<Int>.size
            if sysctlbyname("hw.pagesize", &pageSizeRaw, &pageSizeLen, nil, 0) != 0 || pageSizeRaw <= 0 {
                pageSizeRaw = 4096
            }
            let pageSize = UInt64(pageSizeRaw)
            let freeMB   = (UInt64(vm.free_count)     * pageSize) / (1024 * 1024)
            let activeMB = (UInt64(vm.active_count)   * pageSize) / (1024 * 1024)
            let wiredMB  = (UInt64(vm.wire_count)     * pageSize) / (1024 * 1024)
            let usedMB   = physMB - freeMB
            lines.append("RAM vm:      free=\(freeMB) MB  active=\(activeMB) MB  wired=\(wiredMB) MB  used≈\(usedMB) MB")
        }

        // ── Memory: this process's resident set size ───────────────────────────
        if let residentMB = _residentSetSizeMB() {
            lines.append("RAM this:    \(residentMB) MB resident")
        }

        // ── Thermal state + low-power mode ────────────────────────────────────
        let thermal = _thermalStateString(ProcessInfo.processInfo.thermalState)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        lines.append("Thermal:     \(thermal)  low-power=\(lowPower)")

        // ── Disk: data-dir volume ─────────────────────────────────────────────
        if let disk = _diskInfo() {
            let freeMB  = disk.free  / (1024 * 1024)
            let totalMB = disk.total / (1024 * 1024)
            let usedMB  = totalMB - freeMB
            lines.append("Disk:        free=\(freeMB) MB  used=\(usedMB) MB  total=\(totalMB) MB  (at \(disk.path))")
        }

        // ── Locale + uptime ───────────────────────────────────────────────────
        let locale = Locale.current.identifier
        let uptimeH = ProcessInfo.processInfo.systemUptime / 3600
        lines.append("Locale:      \(locale)")
        lines.append(String(format: "Uptime:      %.1f h", uptimeH))

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Reads a NUL-terminated C-string sysctl value by name.
    static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        // Drop the trailing NUL byte before decoding (size may include it).
        let validBytes = buf.prefix(while: { $0 != 0 })
        return String(decoding: validBytes, as: UTF8.self)
    }

    /// Live VM statistics via `host_statistics64(HOST_VM_INFO64)`.
    private static func _vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// This process's resident set size in MB via `task_info(MACH_TASK_BASIC_INFO)`.
    private static func _residentSetSizeMB() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size) / (1024 * 1024)
    }

    /// Free + total bytes at the Vocateca data-dir volume.
    private static func _diskInfo() -> (free: UInt64, total: UInt64, path: String)? {
        // Use the user-data directory (creates it as a side-effect, but that's
        // acceptable — Paths.userDataDir() already creates it on every call).
        let dir = Paths.userDataDir()
        do {
            let vals = try dir.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey,
            ])
            guard
                let freeInt  = vals.volumeAvailableCapacity, freeInt >= 0,
                let totalInt = vals.volumeTotalCapacity, totalInt >= 0
            else { return nil }
            return (UInt64(freeInt), UInt64(totalInt), dir.path)
        } catch {
            return nil
        }
    }

    /// Human-readable string for `ProcessInfo.ThermalState`.
    private static func _thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Current CPU architecture as a readable string, determined at compile time.
    private static func _currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown-arch"
        #endif
    }
}
