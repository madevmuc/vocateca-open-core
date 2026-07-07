import XCTest
@testable import VocatecaCore

/// `Pipeline.phaseStep` is the single source of truth that splits an overall
/// pipeline fraction back into the current phase's own 0…1 fraction + step index
/// for the two-step queue progress bar. These lock the boundary behaviour.
final class PipelinePhaseStepTests: XCTestCase {

    func testDownloadPhaseMapsToFirstStepFullRange() {
        // Download band is overall 0 … 0.12 → step 1/2, fraction 0 … 1.
        let start = Pipeline.phaseStep(overall: 0.0, isDownloading: true)
        XCTAssertEqual(start.step, 1); XCTAssertEqual(start.total, 2)
        XCTAssertEqual(start.fraction, 0.0, accuracy: 0.0001)

        let mid = Pipeline.phaseStep(overall: 0.06, isDownloading: true)
        XCTAssertEqual(mid.fraction, 0.5, accuracy: 0.0001)

        let end = Pipeline.phaseStep(overall: 0.12, isDownloading: true)
        XCTAssertEqual(end.fraction, 1.0, accuracy: 0.0001)
    }

    func testTranscribePhaseMapsToSecondStepFullRange() {
        // Transcribe band is overall 0.12 … 1.0 → step 2/2, fraction 0 … 1.
        let start = Pipeline.phaseStep(overall: 0.12, isDownloading: false)
        XCTAssertEqual(start.step, 2); XCTAssertEqual(start.total, 2)
        XCTAssertEqual(start.fraction, 0.0, accuracy: 0.0001)

        // Overall 0.56 = 0.12 + 0.5 * 0.88 → halfway through transcription.
        let mid = Pipeline.phaseStep(overall: 0.12 + 0.5 * 0.88, isDownloading: false)
        XCTAssertEqual(mid.fraction, 0.5, accuracy: 0.0001)

        let end = Pipeline.phaseStep(overall: 1.0, isDownloading: false)
        XCTAssertEqual(end.fraction, 1.0, accuracy: 0.0001)
    }

    func testFractionIsClampedToUnitRange() {
        // Out-of-band inputs never produce a fraction outside 0…1.
        XCTAssertEqual(Pipeline.phaseStep(overall: -0.5, isDownloading: true).fraction, 0.0, accuracy: 0.0001)
        XCTAssertEqual(Pipeline.phaseStep(overall: 2.0, isDownloading: true).fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(Pipeline.phaseStep(overall: 0.0, isDownloading: false).fraction, 0.0, accuracy: 0.0001)
    }
}
