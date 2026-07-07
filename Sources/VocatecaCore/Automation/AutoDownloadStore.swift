import Foundation

// MARK: - AutoDownloadStore

/// Typed wrapper over the per-show auto-download flag stored in `UserDefaults`
/// under the key `"autoDownload-<slug>"`.
///
/// Replaces stringly-typed `UserDefaults.standard.bool(forKey: "autoDownload-\(slug)")`
/// calls at every call site (ShowDetailsSheet, IngestCoordinator) with a single
/// well-typed API. The key format is **unchanged** — existing ShowDetailsSheet writes
/// remain compatible.
///
/// ## Key contract
/// Key: `"autoDownload-<slug>"` (e.g. `"autoDownload-lex-fridman-podcast"`)
/// Type: Bool (stored via `UserDefaults.set(_:forKey:)`).
/// Default when absent: `false` (safe-by-default — no shows auto-download until opted in).
///
/// ## Thread safety
/// `UserDefaults` is thread-safe for individual reads and writes. `AutoDownloadStore`
/// is a value type (`struct`) with no mutable state of its own; it is `Sendable`.
/// `@unchecked Sendable` because `UserDefaults` is thread-safe for individual
/// reads and writes (its API contract guarantees this) but is not annotated as
/// `Sendable` in the Foundation headers. The struct holds no mutable state of its
/// own, so the `@unchecked` suppression is sound.
public struct AutoDownloadStore: @unchecked Sendable {

    // MARK: - Key format

    /// The `UserDefaults` key for `slug`.
    /// Internal visibility so tests and sibling code can verify key format.
    static func key(for slug: String) -> String {
        "autoDownload-\(slug)"
    }

    // MARK: - Dependencies

    private let defaults: UserDefaults

    // MARK: - Init

    /// Creates an `AutoDownloadStore` backed by `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to read/write. Defaults to
    ///   `.standard` (production). Inject a named suite in tests.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    /// Returns `true` when auto-download is explicitly enabled for `slug`.
    ///
    /// Defaults to `false` when the key is absent (safe-by-default: a show that
    /// has never been explicitly opted in never triggers the daemon).
    ///
    /// - Parameter slug: The show slug, e.g. `"lex-fridman-podcast"`.
    public func isEnabled(slug: String) -> Bool {
        defaults.bool(forKey: Self.key(for: slug))
    }

    // MARK: - Write

    /// Sets the auto-download flag for `slug`.
    ///
    /// - Parameters:
    ///   - on: `true` to enable auto-download for this show; `false` to disable.
    ///   - slug: The show slug.
    public func setEnabled(_ on: Bool, slug: String) {
        defaults.set(on, forKey: Self.key(for: slug))
    }

    // MARK: - Batch query

    /// Returns the subset of `slugs` for which auto-download is enabled.
    ///
    /// The daemon calls this to discover which shows to include in the auto-download
    /// run. With no shows opted in, this returns `[]` → the daemon processes nothing.
    ///
    /// - Parameter slugs: The full set of show slugs to test.
    /// - Returns: The slugs in `slugs` for which `isEnabled(slug:)` returns `true`.
    public func enabledSlugs(among slugs: [String]) -> [String] {
        slugs.filter { isEnabled(slug: $0) }
    }

    // MARK: - Ingest-status decision (pure helper, TDD-able)

    /// Returns the ``EpisodeStatus`` a freshly-discovered episode should be assigned
    /// at ingest time, based on whether auto-download is enabled for its show.
    ///
    /// - `autoDownloadOn == true`  → `.pending`  (claimed by queue worker → auto-downloaded)
    /// - `autoDownloadOn == false` → `.deferred` (ignored by `claimNextPending`; user
    ///   must explicitly enqueue via "Transcribe now" or the requeue action)
    ///
    /// This is the central safe-by-default gate: without any show opted in,
    /// all newly-ingested episodes land in `.deferred` and the daemon's queue drain
    /// claims nothing new.
    ///
    /// - Parameter autoDownloadOn: The auto-download flag for the episode's show.
    /// - Returns: `.pending` or `.deferred`.
    public static func ingestStatus(autoDownloadOn: Bool) -> EpisodeStatus {
        autoDownloadOn ? .pending : .deferred
    }
}
