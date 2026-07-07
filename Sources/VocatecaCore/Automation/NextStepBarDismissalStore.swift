import Foundation

// MARK: - NextStepBarDismissalStore

/// Typed wrapper over the single dismissed-batch fingerprint for the Shows
/// pane's „Nächster Schritt"-Leiste, stored in `UserDefaults` under the key
/// `"nextStepBar.dismissedFingerprint"`.
///
/// One global fingerprint (not per-show) — the bar itself is a single
/// pane-wide next-best-action, not a per-show affordance. Mirrors
/// `AutoDownloadStore`/`ForceTranscribeStore`'s UserDefaults-backed pattern so
/// the UI (bar's "Ausblenden") and the pure decision logic
/// (`NextStepSuggestion.compute`) share state without a DB round trip for what
/// is a purely presentational "don't show me this again" preference.
///
/// ## Key contract
/// Key: `"nextStepBar.dismissedFingerprint"`.
/// Type: `String?` (stored via `UserDefaults.set(_:forKey:)` /
/// `removeObject(forKey:)`). Absent = nothing ever dismissed.
///
/// `@unchecked Sendable` for the same reason as `AutoDownloadStore`:
/// `UserDefaults` is thread-safe for individual reads/writes per its own API
/// contract, but isn't `Sendable`-annotated in the Foundation headers; the
/// struct holds no mutable state of its own.
public struct NextStepBarDismissalStore: @unchecked Sendable {

    /// Internal visibility so tests can verify the key format.
    static let key = "nextStepBar.dismissedFingerprint"

    private let defaults: UserDefaults

    /// - Parameter defaults: The `UserDefaults` suite to read/write. Defaults
    ///   to `.standard` (production). Inject a named suite in tests.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last-dismissed fingerprint, or `nil` if nothing has ever been
    /// dismissed (or a fresh install).
    public func dismissedFingerprint() -> String? {
        defaults.string(forKey: Self.key)
    }

    /// Persists `fingerprint` as the dismissed batch — call when the user taps
    /// "Ausblenden". A later batch (different pending count and/or newest
    /// pub-date) produces a different fingerprint and is unaffected.
    public func dismiss(fingerprint: String) {
        defaults.set(fingerprint, forKey: Self.key)
    }
}
