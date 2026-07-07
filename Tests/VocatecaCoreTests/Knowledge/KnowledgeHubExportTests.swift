import XCTest
@testable import VocatecaCore

final class KnowledgeHubExportTests: XCTestCase {

    func testEmptyWhenNothingConfigured() {
        XCTAssertTrue(KnowledgeHub.exportRoots(
            exportRoot: "", obsidianVaultPath: "", obsidianVaultName: "knowledge-hub",
            knowledgeHubRoot: "").isEmpty)
    }

    func testExportRootOnly() {
        let roots = KnowledgeHub.exportRoots(
            exportRoot: "/tmp/exports", obsidianVaultPath: "",
            obsidianVaultName: "", knowledgeHubRoot: "")
        XCTAssertEqual(roots.map(\.path), ["/tmp/exports"])
    }

    func testObsidianVaultAppendsName() {
        let roots = KnowledgeHub.exportRoots(
            exportRoot: "", obsidianVaultPath: "/Users/x/Vault",
            obsidianVaultName: "knowledge-hub", knowledgeHubRoot: "")
        XCTAssertEqual(roots.map(\.path), ["/Users/x/Vault/knowledge-hub"])
    }

    func testObsidianVaultNoNameUsesBase() {
        let roots = KnowledgeHub.exportRoots(
            exportRoot: "", obsidianVaultPath: "/Users/x/Vault",
            obsidianVaultName: "  ", knowledgeHubRoot: "")
        XCTAssertEqual(roots.map(\.path), ["/Users/x/Vault"])
    }

    func testAllThreeDedupedOrdered() {
        let roots = KnowledgeHub.exportRoots(
            exportRoot: "/a", obsidianVaultPath: "/b", obsidianVaultName: "v",
            knowledgeHubRoot: "/a")   // /a duplicated → collapsed
        XCTAssertEqual(roots.map(\.path), ["/a", "/b/v"])
    }
}
