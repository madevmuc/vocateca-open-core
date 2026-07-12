import Foundation

/// Top-level namespace + version marker for the Vocateca core library.
public enum Vocateca {
    /// Hardcoded fallback used only when no `Info.plist` is available to read
    /// from (unbundled CLI, `swift test`, dev runs without a packaged
    /// `.app`). Bump this alongside real releases so the fallback stays
    /// close to reality, but it is never authoritative for a built `.app` —
    /// that always reads the real, templated `CFBundleShortVersionString`.
    private static let fallbackVersion = "2.0.2"

    /// Marketing version of the native v2 build (e.g. `"2.0.1"`), read live
    /// from the app bundle's `CFBundleShortVersionString` (populated at
    /// build time from `packaging/Info.plist.template`'s
    /// `__MARKETING_VERSION__`). Falls back to `fallbackVersion` when no
    /// bundle `Info.plist` is present (unbundled CLI / dev / tests).
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }

    /// Build identifier of the native v2 build (e.g. `"20001"`), read live
    /// from the app bundle's `CFBundleVersion` (populated at build time from
    /// `packaging/Info.plist.template`'s `__BUILD_VERSION__`). Falls back to
    /// `"0"` when no bundle `Info.plist` is present (unbundled CLI / dev /
    /// tests).
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Human-readable "version (build)" string for UI display, e.g.
    /// `"2.0.1 (20001)"`. Omits the build suffix when no real build ID is
    /// available (i.e. `build` is still at its `"0"` fallback), so unbundled
    /// contexts show a plain version instead of `"2.0.1 (0)"`.
    public static var versionDisplay: String {
        build == "0" ? version : "\(version) (\(build))"
    }
}
