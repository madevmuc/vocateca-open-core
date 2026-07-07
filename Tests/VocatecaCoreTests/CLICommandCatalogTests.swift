import XCTest
@testable import VocatecaCore

final class CLICommandCatalogTests: XCTestCase {

    func testCatalogIsNonEmpty() {
        XCTAssertFalse(CLICommandCatalog.all.isEmpty, "catalog should document commands")
    }

    func testEveryEntryHasNonEmptyGroupCommandSummary() {
        for doc in CLICommandCatalog.all {
            XCTAssertFalse(doc.group.trimmingCharacters(in: .whitespaces).isEmpty,
                           "empty group for command '\(doc.command)'")
            XCTAssertFalse(doc.command.trimmingCharacters(in: .whitespaces).isEmpty,
                           "empty command in group '\(doc.group)'")
            XCTAssertFalse(doc.summary.trimmingCharacters(in: .whitespaces).isEmpty,
                           "empty summary for command '\(doc.command)'")
        }
    }

    func testEveryGroupIsFromTheKnownSet() {
        let known = Set(CLICommandCatalog.groups)
        for doc in CLICommandCatalog.all {
            XCTAssertTrue(known.contains(doc.group),
                          "command '\(doc.command)' uses unknown group '\(doc.group)'")
        }
    }

    func testTopLevelCommandsHaveNoDuplicates() {
        let names = CLICommandCatalog.topLevelCommands
        XCTAssertEqual(names.count, Set(names).count,
                       "topLevelCommands contains duplicates")
    }

    func testConventionsBlurbIsNonEmpty() {
        XCTAssertFalse(CLICommandCatalog.conventions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Every top-level command name should be a prefix of at least one catalog
    /// command (so the catalog actually documents the dispatched surface).
    func testTopLevelCommandsAreDocumented() {
        // Commands documented only via aliases in a summary (e.g. `list` → shows).
        let documentedViaAlias: Set<String> = []
        for name in CLICommandCatalog.topLevelCommands where !documentedViaAlias.contains(name) {
            let documented = CLICommandCatalog.all.contains { doc in
                doc.command == name || doc.command.hasPrefix(name + " ")
            }
            XCTAssertTrue(documented, "top-level command '\(name)' has no catalog entry")
        }
    }
}
