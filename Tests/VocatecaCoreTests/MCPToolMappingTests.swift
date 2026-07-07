import XCTest
@testable import VocatecaCore

final class MCPToolMappingTests: XCTestCase {

    func testAllToolNamesAreUnique() {
        let tools = MCPToolMapping.tools()
        let names = tools.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate MCP tool names: \(names)")
        XCTAssertEqual(names.count, CLICommandCatalog.all.count)
    }

    func testKnownCommandPathDerivation() {
        XCTAssertEqual(MCPToolMapping.baseName(for: doc("status")), "status")
        XCTAssertEqual(MCPToolMapping.baseName(for: doc("sources add-podcast <feed-url>")), "sources_add-podcast")
        XCTAssertEqual(MCPToolMapping.baseName(for: doc("queue stop-after <guid>")), "queue_stop-after")
        XCTAssertEqual(MCPToolMapping.baseName(for: doc("retry --all")), "retry")
    }

    func testRetryCollisionIsDisambiguated() {
        let tools = MCPToolMapping.tools()
        let retryNames = tools.filter { $0.doc.command.hasPrefix("retry") }.map(\.name)
        XCTAssertEqual(Set(retryNames), Set(["retry", "retry_all"]))
    }

    func testMutatingToolGetsDryRunProperty() {
        let mutatingDoc = doc("sources add-podcast <feed-url>")
        let schema = MCPToolMapping.inputSchema(for: mutatingDoc)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["dry_run"])
        let required = schema["required"] as? [String]
        XCTAssertFalse(required?.contains("dry_run") ?? true)
    }

    func testReadOnlyToolHasNoDryRunProperty() {
        let readDoc = doc("status")
        let schema = MCPToolMapping.inputSchema(for: readDoc)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNil(properties?["dry_run"])
    }

    func testRequiredArgumentsPropagateToSchema() {
        let episodesDoc = doc("episodes <slug>")
        let schema = MCPToolMapping.inputSchema(for: episodesDoc)
        let required = schema["required"] as? [String]
        XCTAssertEqual(required, ["slug"])
        let properties = schema["properties"] as? [String: Any]
        let limit = properties?["limit"] as? [String: Any]
        XCTAssertEqual(limit?["type"] as? String, "integer")
    }

    func testArgvBuildsPositionalFlagAndBooleanArgsInOrder() {
        let addPodcastDoc = doc("sources add-podcast <feed-url>")
        let argv = MCPToolMapping.argv(for: addPodcastDoc, arguments: [
            "feed-url": "https://example.com/feed.xml",
            "title": "My Show",
            "poll": true,
        ])
        XCTAssertEqual(argv, [
            "sources", "add-podcast",
            "https://example.com/feed.xml",
            "--title", "My Show",
            "--poll",
            "--json",
        ])
    }

    func testArgvOmitsFalseBooleanFlags() {
        let addPodcastDoc = doc("sources add-podcast <feed-url>")
        let argv = MCPToolMapping.argv(for: addPodcastDoc, arguments: [
            "feed-url": "https://example.com/feed.xml",
            "poll": false,
        ])
        XCTAssertEqual(argv, [
            "sources", "add-podcast",
            "https://example.com/feed.xml",
            "--json",
        ])
    }

    func testArgvAppendsDryRunOnlyForMutatingWhenRequested() {
        let addPodcastDoc = doc("sources add-podcast <feed-url>")
        let argv = MCPToolMapping.argv(for: addPodcastDoc, arguments: [
            "feed-url": "https://example.com/feed.xml",
            "dry_run": true,
        ])
        XCTAssertEqual(argv.last, "--dry-run")

        let statusDoc = doc("status")
        let readArgv = MCPToolMapping.argv(for: statusDoc, arguments: ["dry_run": true])
        XCTAssertFalse(readArgv.contains("--dry-run"))
    }

    // MARK: - Helpers

    private func doc(_ command: String) -> CLICommandDoc {
        guard let match = CLICommandCatalog.all.first(where: { $0.command == command }) else {
            XCTFail("no CLICommandDoc with command \(command)")
            return CLICommandDoc(group: "", command: command, summary: "")
        }
        return match
    }
}
