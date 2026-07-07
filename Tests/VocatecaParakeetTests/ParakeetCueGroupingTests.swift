import XCTest
@testable import VocatecaParakeet
import VocatecaCore

final class ParakeetCueGroupingTests: XCTestCase {
    func testGroupsWordsIntoCuesAndBreaksOnSentenceEnd() {
        let words = [("Hallo", 0.0, 0.4), ("Welt.", 0.4, 0.9), ("Zweiter", 1.0, 1.5), ("Satz", 1.5, 2.0)]
            .map { (text: $0.0, start: $0.1, end: $0.2) }
        let segs = ParakeetCueGrouping.segments(fromWords: words)
        XCTAssertEqual(segs?.count, 2)
        XCTAssertEqual(segs?.first?.text, "Hallo Welt.")
        XCTAssertEqual(segs?.first?.start, 0.0)
        XCTAssertEqual(segs?.last?.end, 2.0)
    }
    func testEmptyOrZeroSpanReturnsNil() {
        XCTAssertNil(ParakeetCueGrouping.segments(fromWords: []))
    }
}
