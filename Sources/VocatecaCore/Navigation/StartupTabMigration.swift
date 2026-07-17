// MARK: - StartupTabMigration

/// Maps a persisted tab identifier onto one that still exists.
///
/// `Settings.startupTab` (YAML `startup_tab`) and the `"lastUsedTab"` UserDefaults
/// key both store a raw `SidebarItem` rawValue. Whenever a tab is removed or its
/// rawValue is renamed, every settings.yaml written before that change points at
/// a tab this build no longer has — the app would silently open somewhere the
/// user never chose.
///
/// This type is deliberately UI-free (like ``StartupTabResolver``): the caller
/// passes in the set of rawValues this build actually knows, so the rules stay
/// directly testable from `VocatecaCoreTests` without a UI test target.
public enum StartupTabMigration {

    /// Retired rawValues and the tab that took over their job.
    ///
    /// - `Watchlist` → `Keyword Watchlist`: a pure rename. The tab had displayed
    ///   the "Keyword Watchlist" label for a while (users confused it with the
    ///   show subscriptions, whose file is literally `watchlist.yaml`) while its
    ///   rawValue stayed behind; the two are now consistent.
    /// - `Podcasts` / `YouTube` / `Instagram` → `Shows`: the per-source tabs were
    ///   merged into the single Shows list.
    /// - `Local Ingest` / `YouTube Explorer` → `Add`: both were doors for getting
    ///   something into the app, each with its own tab. The Add tab does what
    ///   they did — files and a drop zone, and a video with its transcript — so
    ///   whoever started on either of them still starts on the screen that
    ///   answers the same question.
    /// - `Creators` → `Shows`: a creator was never a stored thing, only a way of
    ///   grouping the shows, so the tab became a mode on Shows. Whoever started
    ///   on Creators lands on the list that now contains it; the by-person mode
    ///   is one click away and remembers being chosen.
    public static let renames: [String: String] = [
        "Watchlist":        "Keyword Watchlist",
        "Podcasts":         "Shows",
        "YouTube":          "Shows",
        "Instagram":        "Shows",
        "Local Ingest":     "Add",
        "YouTube Explorer": "Add",
        "Creators":         "Shows",
    ]

    /// Resolves `rawTab` to a tab that exists in this build.
    ///
    /// Rules, in order:
    ///   1. A rawValue this build knows is kept as-is.
    ///   2. A retired rawValue is followed through ``renames`` — but only if the
    ///      replacement itself exists; a rename to a since-removed tab is treated
    ///      as unknown rather than trusted blindly.
    ///   3. Anything else (a tab removed without a rename entry, a typo, a value
    ///      hand-edited into settings.yaml) falls back to `fallback`.
    ///
    /// - Parameters:
    ///   - rawTab: The persisted `SidebarItem.rawValue`.
    ///   - knownTabs: Every rawValue this build has (`SidebarItem.allCases`).
    ///   - fallback: Where to land when nothing matches; must itself be known,
    ///     otherwise it is returned anyway (the caller's own default is the last
    ///     line of defence).
    /// - Returns: A rawValue that exists in `knownTabs`, or `fallback`.
    public static func migrate(
        rawTab: String,
        knownTabs: Set<String>,
        fallback: String = "Shows"
    ) -> String {
        if knownTabs.contains(rawTab) { return rawTab }
        if let renamed = renames[rawTab], knownTabs.contains(renamed) {
            Log.info("Startup tab migrated", component: "Navigation",
                     context: [("from", rawTab), ("to", renamed)])
            return renamed
        }
        Log.warn("Startup tab unknown — falling back", component: "Navigation",
                 context: [("raw", rawTab), ("fallback", fallback)])
        return fallback
    }
}
