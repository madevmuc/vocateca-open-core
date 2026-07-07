import XCTest
@testable import VocatecaCore

/// Golden-fixture tests for ``TextNormalization``.
///
/// Each test loads the corresponding JSON fixture produced by the Python reference
/// oracle and asserts byte-for-byte equality for every case. The fixture files live
/// at `Tests/VocatecaCoreTests/Fixtures/oracle/` and are bundled via the
/// `resources: [.copy("Fixtures")]` declaration in Package.swift.
///
/// Do NOT edit the JSON fixtures to make tests pass — the Python oracle is authoritative.
final class OracleTextTests: XCTestCase {

    // MARK: - Helpers

    private struct OracleCase: Decodable {
        let input: String
        let output: String
    }

    private func loadFixture(named filename: String) throws -> [OracleCase] {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "Fixtures/oracle"
        ) else {
            XCTFail("Fixture not found in bundle: Fixtures/oracle/\(filename).json")
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([OracleCase].self, from: data)
    }

    // MARK: - slugify

    func testSlugify() throws {
        let cases = try loadFixture(named: "slugify")
        XCTAssertFalse(cases.isEmpty, "slugify fixture is empty")
        var failures = 0
        for c in cases {
            let got = TextNormalization.slugify(c.input)
            if got != c.output {
                XCTFail("""
                    slugify mismatch:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("slugify: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - sanitizeFilename

    func testSanitizeFilename() throws {
        let cases = try loadFixture(named: "sanitize_filename")
        XCTAssertFalse(cases.isEmpty, "sanitize_filename fixture is empty")
        var failures = 0
        for c in cases {
            let got = TextNormalization.sanitizeFilename(c.input)
            if got != c.output {
                XCTFail("""
                    sanitizeFilename mismatch:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("sanitizeFilename: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - normalizeTitle

    func testNormalizeTitle() throws {
        let cases = try loadFixture(named: "normalize_title")
        XCTAssertFalse(cases.isEmpty, "normalize_title fixture is empty")
        var failures = 0
        for c in cases {
            let got = TextNormalization.normalizeTitle(c.input)
            if got != c.output {
                XCTFail("""
                    normalizeTitle mismatch:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("normalizeTitle: all \(cases.count) cases passed ✓")
        }
    }
}
