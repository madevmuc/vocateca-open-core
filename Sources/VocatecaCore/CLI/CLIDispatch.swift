import Foundation

/// The set of top-level commands the `vocateca-cli` dispatcher actually handles.
///
/// This constant is the **authoritative dispatch list**: `main.swift` references
/// it (to validate unknown commands and to know what it handles), and the
/// drift-guard parity test asserts `Set(CLIDispatch.handledCommands) ==
/// Set(CLICommandCatalog.topLevelCommands)`. So adding a command to the CLI
/// without also cataloguing it (or vice-versa) fails the test.
///
/// Lives in `VocatecaCore` (not the executable target) purely so the Core test
/// suite can import it — Swift test targets cannot `@testable import` an
/// executable. main.swift consumes it, keeping the dispatch tied to this list.
public enum CLIDispatch {

    /// Primary names dispatched in main.swift's `switch parsed.command`. Aliases
    /// (`list` → `shows`) and flag-forms (`--version`, `--help`, `-h`) are NOT
    /// listed here — this is the set of primary command names, matching
    /// `CLICommandCatalog.topLevelCommands`.
    public static let handledCommands: [String] = [
        "version",
        "status",
        "shows",
        "episodes",
        "failed",
        "stats",
        "health",
        "feed-health",
        "ig-doctor",
        "sources",
        "transcribe",
        "queue",
        "library",
        "integrations",
        "settings",
        "engine",
        "retry",
        "notifications",
        "docs",
        "help",
        "mcp",
    ]
}
