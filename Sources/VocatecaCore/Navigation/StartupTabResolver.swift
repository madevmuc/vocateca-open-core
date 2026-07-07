// MARK: - StartupTabResolver

/// Pure startup-tab resolution logic (no UI dependencies).
///
/// `AppShell.resolveStartupTab` wraps this to map the returned string to a
/// `SidebarItem`. Keeping it in `VocatecaCore` makes it directly testable
/// from `VocatecaCoreTests` without a UI test target.
///
/// Resolution rules:
///   1. If `openOnLastUsed` is `true`: use `lastUsed`, falling back to `fallback`.
///   2. If `openOnLastUsed` is `false`: use `explicitTab`.
///   3. In both cases, an empty or nil result falls back to `fallback`.
public enum StartupTabResolver {

    /// Resolves the raw tab name (a `SidebarItem.rawValue`) for this launch.
    ///
    /// - Parameters:
    ///   - openOnLastUsed: Maps to `Settings.openOnLastUsedTab`.
    ///   - lastUsed: The raw tab name stored in UserDefaults from the previous
    ///     session; `nil` when the app has never been launched before.
    ///   - explicitTab: Maps to `Settings.startupTab`; used when
    ///     `openOnLastUsed` is `false`.
    ///   - fallback: The raw tab name to use when every other option is empty
    ///     or nil. Defaults to `"Shows"`.
    /// - Returns: The raw `SidebarItem` name for the initial tab selection.
    public static func resolve(
        openOnLastUsed: Bool,
        lastUsed: String?,
        explicitTab: String,
        fallback: String = "Shows"
    ) -> String {
        let candidate: String
        if openOnLastUsed {
            candidate = lastUsed ?? ""
        } else {
            candidate = explicitTab
        }
        return candidate.isEmpty ? fallback : candidate
    }
}
