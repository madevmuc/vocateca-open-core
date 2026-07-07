import XCTest
@testable import VocatecaCore

/// Unit tests for ``TranscriptOrigin`` — storage round-trip + display labels.
final class TranscriptOriginTests: XCTestCase {

    func testStorageRoundTrip() {
        let cases: [TranscriptOrigin] = [
            .captions(.auto),
            .captions(.manual),
            .whisper(model: "openai_whisper-large-v3-turbo"),
            .whisper(model: "openai_whisper-tiny", fastMode: true),
            .asr(engine: "qwen3-asr", model: "qwen3-asr-flash"),  // future engine
            .ocr,
        ]
        for origin in cases {
            let s = origin.storageString
            let parsed = TranscriptOrigin.parse(s)
            XCTAssertEqual(parsed, origin, "round-trip failed for \(s)")
        }
    }

    func testStorageStrings() {
        XCTAssertEqual(TranscriptOrigin.captions(.auto).storageString, "captions:auto")
        XCTAssertEqual(TranscriptOrigin.captions(.manual).storageString, "captions:manual")
        // Engine-agnostic ASR layout — engine is part of the key.
        XCTAssertEqual(TranscriptOrigin.whisper(model: "m").storageString, "asr:whisper:m")
        XCTAssertEqual(TranscriptOrigin.whisper(model: "m", fastMode: true).storageString, "asr:whisper:m:fast")
        XCTAssertEqual(TranscriptOrigin.asr(engine: "qwen3-asr", model: "flash").storageString, "asr:qwen3-asr:flash")
        XCTAssertEqual(TranscriptOrigin.ocr.storageString, "ocr")
    }

    /// The pre-engine-agnostic `"whisper:<model>"` layout must still parse.
    func testParseLegacyWhisperLayout() {
        XCTAssertEqual(TranscriptOrigin.parse("whisper:openai_whisper-tiny"),
                       .whisper(model: "openai_whisper-tiny"))
        XCTAssertEqual(TranscriptOrigin.parse("whisper:m:fast"),
                       .whisper(model: "m", fastMode: true))
    }

    func testParseEmptyOrUnknownReturnsNil() {
        XCTAssertNil(TranscriptOrigin.parse(nil))
        XCTAssertNil(TranscriptOrigin.parse(""))
        XCTAssertNil(TranscriptOrigin.parse("garbage"))
    }

    func testDisplayLabels() {
        XCTAssertEqual(TranscriptOrigin.captions(.auto).displayLabel, "Captions · auto-generated")
        XCTAssertEqual(TranscriptOrigin.captions(.manual).displayLabel, "Captions · author-provided")
        XCTAssertEqual(TranscriptOrigin.ocr.displayLabel, "Image OCR · Apple Vision")
        // Whisper model name is cleaned of the HuggingFace repo prefix.
        XCTAssertEqual(
            TranscriptOrigin.whisper(model: "openai_whisper-large-v3-turbo").displayLabel,
            "Whisper · large-v3-turbo")
        XCTAssertEqual(
            TranscriptOrigin.whisper(model: "openai_whisper-tiny", fastMode: true).displayLabel,
            "Whisper · tiny · fast")
        // A different engine renders with its own display name; non-Whisper model
        // ids pass through uncleaned.
        XCTAssertEqual(
            TranscriptOrigin.asr(engine: "qwen3-asr", model: "qwen3-asr-flash").displayLabel,
            "Qwen3-ASR · qwen3-asr-flash")
        XCTAssertTrue(
            TranscriptOrigin.asr(engine: "parakeet", model: "tdt-0.6b-v3").displayLabel.hasPrefix("Parakeet"))
    }

    func testTranscriptionResultCarriesOrigin() {
        let base = TranscriptionResult(text: "hi", segments: [], language: "en")
        XCTAssertNil(base.origin)
        let tagged = base.withOrigin(.captions(.auto))
        XCTAssertEqual(tagged.origin, .captions(.auto))
        XCTAssertEqual(tagged.text, "hi")  // other fields preserved
    }
}
