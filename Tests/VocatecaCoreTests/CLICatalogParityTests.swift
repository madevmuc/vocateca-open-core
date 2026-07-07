import XCTest
@testable import VocatecaCore

/// Drift-guard: the CLI's dispatched command set (`CLIDispatch.handledCommands`,
/// referenced by main.swift's switch/help) must exactly match the catalog's
/// `topLevelCommands`. Adding a command to one without the other fails here.
final class CLICatalogParityTests: XCTestCase {

    func testDispatchAndCatalogAgree() {
        let dispatched = Set(CLIDispatch.handledCommands)
        let catalogued = Set(CLICommandCatalog.topLevelCommands)

        let onlyDispatched = dispatched.subtracting(catalogued)
        let onlyCatalogued = catalogued.subtracting(dispatched)

        XCTAssertTrue(
            onlyDispatched.isEmpty,
            "commands dispatched but not in CLICommandCatalog.topLevelCommands: \(onlyDispatched.sorted())"
        )
        XCTAssertTrue(
            onlyCatalogued.isEmpty,
            "commands catalogued but not in CLIDispatch.handledCommands: \(onlyCatalogued.sorted())"
        )
        XCTAssertEqual(dispatched, catalogued)
    }

    func testHandledCommandsHaveNoDuplicates() {
        let names = CLIDispatch.handledCommands
        XCTAssertEqual(names.count, Set(names).count,
                       "CLIDispatch.handledCommands contains duplicates")
    }

    func testEveryHandledCommandIsDocumented() {
        for name in CLIDispatch.handledCommands {
            let documented = CLICommandCatalog.all.contains { doc in
                doc.command == name || doc.command.hasPrefix(name + " ")
            }
            XCTAssertTrue(documented, "handled command '\(name)' has no catalog entry")
        }
    }

    func testRenderHelpMentionsEveryGroupAndIsNonEmpty() {
        let help = CLICommandCatalog.renderHelp(version: "9.9.9")
        XCTAssertFalse(help.isEmpty)
        XCTAssertTrue(help.contains("9.9.9"))
        for group in CLICommandCatalog.groups {
            // Groups with at least one entry should appear as a heading.
            let hasEntries = CLICommandCatalog.all.contains { $0.group == group }
            if hasEntries {
                XCTAssertTrue(help.contains(group + ":"),
                              "help output missing group heading '\(group)'")
            }
        }
    }
}
