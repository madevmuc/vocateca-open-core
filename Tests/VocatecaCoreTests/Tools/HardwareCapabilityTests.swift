import XCTest
@testable import VocatecaCore

/// Unit tests for the `Hardware` capability parser used by the Qwen engine gate.
/// `chipTier(fromBrand:)` is pure, so it's tested against fixture brand strings
/// (no `sysctl` dependency).
final class HardwareCapabilityTests: XCTestCase {

    func testChipTierFromBrand() {
        let cases: [(String, Hardware.ChipTier)] = [
            ("Apple M1",       .base),
            ("Apple M2",       .base),
            ("Apple M3",       .base),
            ("Apple M4",       .base),
            ("Apple M1 Pro",   .pro),
            ("Apple M2 Pro",   .pro),
            ("Apple M3 Max",   .max),
            ("Apple M2 Max",   .max),
            ("Apple M1 Ultra", .ultra),
            ("Apple M2 Ultra", .ultra),
            // Non-Apple-Silicon → intel (never eligible for the GPU engine).
            ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", .intel),
            ("Intel(R) Xeon(R) W-2150B",                 .intel),
            ("",                                          .intel),
        ]
        for (brand, expected) in cases {
            XCTAssertEqual(Hardware.chipTier(fromBrand: brand), expected,
                           "chipTier(\(brand.debugDescription)) should be \(expected)")
        }
    }

    func testChipTierIsCaseInsensitive() {
        XCTAssertEqual(Hardware.chipTier(fromBrand: "apple m2 pro"), .pro)
        XCTAssertEqual(Hardware.chipTier(fromBrand: "APPLE M1 ULTRA"), .ultra)
    }

    func testLiveHelpersDoNotCrash() {
        // Smoke: live sysctl reads return sane, non-crashing values on the host.
        _ = Hardware.isAppleSilicon()
        XCTAssertGreaterThanOrEqual(Hardware.unifiedMemoryGB(), 0)
    }
}
