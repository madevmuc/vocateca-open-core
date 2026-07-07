import XCTest
@testable import VocatecaCore

final class IngestCandidateTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testAudioClassified() {
        let c = IngestCandidateClassifier.classify(url("interview.mp3"))
        XCTAssertEqual(c.mediaType, .audio)
        XCTAssertTrue(c.isIngestable)
        XCTAssertEqual(c.name, "interview.mp3")
    }

    func testVideoClassified() {
        let c = IngestCandidateClassifier.classify(url("keynote.MP4")) // case-insensitive
        XCTAssertEqual(c.mediaType, .video)
        XCTAssertTrue(c.isIngestable)
    }

    func testUnsupportedClassified() {
        let c = IngestCandidateClassifier.classify(url("notes.pdf"))
        XCTAssertEqual(c.mediaType, .unsupported)
        XCTAssertFalse(c.isIngestable)
    }

    func testBatchDedupByPath() {
        let urls = [url("a.mp3"), url("b.mov"), url("a.mp3"), url("c.txt")]
        let result = IngestCandidateClassifier.classify(urls: urls)
        XCTAssertEqual(result.map(\.name), ["a.mp3", "b.mov", "c.txt"]) // no duplicate a.mp3
        XCTAssertEqual(result.filter(\.isIngestable).count, 2)          // a.mp3 + b.mov
    }

    func testBatchExcludesAlreadyStaged() {
        let result = IngestCandidateClassifier.classify(
            urls: [url("a.mp3"), url("d.wav")],
            excludingPaths: ["/tmp/a.mp3"]
        )
        XCTAssertEqual(result.map(\.name), ["d.wav"]) // a.mp3 already staged → skipped
    }
}
