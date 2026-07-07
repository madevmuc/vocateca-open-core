import XCTest
@testable import VocatecaCore
final class CLICatalogArgsTests: XCTestCase {
    func testEveryMutatingCommandHasNoDuplicateArgNames() {
        for doc in CLICommandCatalog.all {
            let names = doc.arguments.map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "dup arg in \(doc.command)")
        }
    }
    func testAtLeastOneMutatingAndOneReadOnly() {
        XCTAssertTrue(CLICommandCatalog.all.contains { $0.mutating })
        XCTAssertTrue(CLICommandCatalog.all.contains { !$0.mutating })
    }
    func testKnownArgTypesOnly() {
        for doc in CLICommandCatalog.all { for a in doc.arguments {
            XCTAssertTrue([.string,.integer,.boolean].contains(a.type))
        } }
    }
}
