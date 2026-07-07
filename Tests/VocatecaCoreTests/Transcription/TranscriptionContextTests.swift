import XCTest
@testable import VocatecaCore

/// Task 5: a `TranscriptionContext` threads a per-episode prompt + glossary +
/// language into `transcribe(...)`. The NEW context-aware overload is the sole
/// protocol requirement; a protocol extension makes the existing
/// `transcribe(audioURL:language:progress:)` (and the 2-arg base) forward to it
/// with `context: nil`, so every legacy conformer + call site keeps compiling.
///
/// Class name is unique so `swift test --filter TranscriptionContextTests`
/// selects exactly these.
final class TranscriptionContextTests: XCTestCase {

    /// A minimal conformer that implements ONLY the new context overload
    /// (as real engines will) and records the last context it saw. Because the
    /// protocol extension routes every legacy overload here, the 2-arg and
    /// 3-arg calls must also land in this method.
    private actor RecordingTranscriber: Transcriber {
        private(set) var lastContext: TranscriptionContext?
        private(set) var callCount = 0

        func snapshot() -> (TranscriptionContext?, Int) { (lastContext, callCount) }

        // The protocol's root requirement (no extension default). Every legacy
        // overload ultimately funnels here via the extension chain
        // context → progress → base, so recording here proves the legacy paths
        // carried `context == nil` down to the engine floor.
        func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
            callCount += 1
            return TranscriptionResult(text: "ok", segments: [], language: language)
        }

        // The NEW requirement. A real engine overrides this to consume context;
        // the stub records it, then forwards to the base so `callCount` is shared.
        func transcribe(
            audioURL: URL,
            language: String?,
            context: TranscriptionContext?,
            progress: @escaping ProgressReporter
        ) async throws -> TranscriptionResult {
            lastContext = context
            progress(1.0)
            return try await transcribe(audioURL: audioURL, language: language)
        }
    }

    private let url = URL(fileURLWithPath: "/tmp/x.mp3")

    /// The legacy 2-arg overload forwards with `context == nil`.
    func testLegacyTwoArgDeliversNilContext() async throws {
        let t = RecordingTranscriber()
        _ = try await t.transcribe(audioURL: url, language: "de")
        let (ctx, count) = await t.snapshot()
        XCTAssertNil(ctx)
        XCTAssertEqual(count, 1)
    }

    /// The legacy 3-arg progress overload forwards with `context == nil`.
    func testLegacyProgressOverloadDeliversNilContext() async throws {
        let t = RecordingTranscriber()
        _ = try await t.transcribe(audioURL: url, language: "de", progress: { _ in })
        let (ctx, _) = await t.snapshot()
        XCTAssertNil(ctx)
    }

    /// The new overload delivers exactly the passed context.
    func testNewOverloadDeliversContext() async throws {
        let t = RecordingTranscriber()
        let ctx = TranscriptionContext(prompt: "DOAC, Flightstory",
                                       glossary: ["gocomo", "Firtina"],
                                       language: "de")
        _ = try await t.transcribe(audioURL: url, language: "de", context: ctx, progress: { _ in })
        let (got, _) = await t.snapshot()
        XCTAssertEqual(got?.prompt, "DOAC, Flightstory")
        XCTAssertEqual(got?.glossary, ["gocomo", "Firtina"])
        XCTAssertEqual(got?.language, "de")
    }

    /// `TranscriptionContext` is a value type with sane defaults.
    func testContextDefaults() {
        let ctx = TranscriptionContext()
        XCTAssertNil(ctx.prompt)
        XCTAssertEqual(ctx.glossary, [])
        XCTAssertNil(ctx.language)
    }
}
