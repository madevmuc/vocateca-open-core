import XCTest
@testable import VocatecaCore

final class HardwareTests: XCTestCase {

    func testAutoConcurrencyMirrorsLoadProfiles() {
        // quiet / balanced are always 1, regardless of cores.
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "quiet", perfCores: 16), 1)
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "balanced", perfCores: 16), 1)
        // full → 2 on ≥8 perf cores, else 1.
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "full", perfCores: 8), 2)
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "full", perfCores: 10), 2)
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "full", perfCores: 4), 1)
        // unknown level defaults to 1; zero/negative cores clamp to 1.
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "other", perfCores: 16), 1)
        XCTAssertEqual(Hardware.autoTranscribeConcurrency(loadLevel: "full", perfCores: 0), 1)
    }

    func testPerformanceCoreCountIsPositive() {
        XCTAssertGreaterThanOrEqual(Hardware.performanceCoreCount(), 1)
    }
}
