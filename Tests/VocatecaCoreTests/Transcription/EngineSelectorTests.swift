import XCTest
@testable import VocatecaCore

/// Pure-logic tests for ``EngineSelector`` over a hardware × settings matrix
/// (Qwen design spec §8). Auto-Qwen gate: Apple Silicon Pro/Max/Ultra with ≥24 GB.
final class EngineSelectorTests: XCTestCase {

    // MARK: - Auto gate

    func testAutoQualifiesForQwenGate() {
        // Qualifies: strong chip AND ≥ 24 GB.
        XCTAssertTrue(EngineSelector.autoQualifiesForQwen(chipTier: .pro, unifiedMemoryGB: 24))
        XCTAssertTrue(EngineSelector.autoQualifiesForQwen(chipTier: .max, unifiedMemoryGB: 32))
        XCTAssertTrue(EngineSelector.autoQualifiesForQwen(chipTier: .ultra, unifiedMemoryGB: 64))
        XCTAssertTrue(EngineSelector.autoQualifiesForQwen(chipTier: .pro, unifiedMemoryGB: 36))

        // Disqualifies: base chip (regardless of RAM).
        XCTAssertFalse(EngineSelector.autoQualifiesForQwen(chipTier: .base, unifiedMemoryGB: 64))
        // Disqualifies: Intel.
        XCTAssertFalse(EngineSelector.autoQualifiesForQwen(chipTier: .intel, unifiedMemoryGB: 128))
        // Disqualifies: strong chip but < 24 GB.
        XCTAssertFalse(EngineSelector.autoQualifiesForQwen(chipTier: .pro, unifiedMemoryGB: 16))
        XCTAssertFalse(EngineSelector.autoQualifiesForQwen(chipTier: .max, unifiedMemoryGB: 18))
    }

    // MARK: - resolve: explicit overrides bypass the gate

    func testExplicitWhisperAlwaysWhisper() {
        XCTAssertEqual(EngineSelector.resolve(preference: .whisper, chipTier: .ultra, unifiedMemoryGB: 128), .whisper)
        XCTAssertEqual(EngineSelector.resolve(preference: .whisper, chipTier: .base, unifiedMemoryGB: 8), .whisper)
    }

    func testExplicitQwenAlwaysQwenEvenOnWeakHardware() {
        // Honoured even on sub-gate hardware (UI warns; runtime fallback is separate).
        XCTAssertEqual(EngineSelector.resolve(preference: .qwen, chipTier: .base, unifiedMemoryGB: 8), .qwen)
        XCTAssertEqual(EngineSelector.resolve(preference: .qwen, chipTier: .intel, unifiedMemoryGB: 16), .qwen)
        XCTAssertEqual(EngineSelector.resolve(preference: .qwen, chipTier: .max, unifiedMemoryGB: 32), .qwen)
    }

    // MARK: - resolve: auto resolves to Parakeet on Apple Silicon, Whisper on Intel

    func testAutoResolvesToParakeetOnAppleSilicon() {
        // Any Apple Silicon chip tier → Parakeet, regardless of the old Qwen RAM/tier gate.
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .base, unifiedMemoryGB: 16), .parakeet)
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .pro, unifiedMemoryGB: 24), .parakeet)
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .max, unifiedMemoryGB: 32), .parakeet)
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .ultra, unifiedMemoryGB: 64), .parakeet)
        // Even sub-gate (low RAM) Apple Silicon still resolves to Parakeet, not Whisper.
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .pro, unifiedMemoryGB: 16), .parakeet)
    }

    func testAutoFallsBackToWhisperOnIntel() {
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .intel, unifiedMemoryGB: 64), .whisper)
        XCTAssertEqual(EngineSelector.resolve(preference: .auto, chipTier: .intel, unifiedMemoryGB: 8), .whisper)
    }

    // MARK: - resolve: explicit .parakeet

    func testExplicitParakeetOnAppleSilicon() {
        XCTAssertEqual(EngineSelector.resolve(preference: .parakeet, chipTier: .base, unifiedMemoryGB: 8), .parakeet)
        XCTAssertEqual(EngineSelector.resolve(preference: .parakeet, chipTier: .max, unifiedMemoryGB: 64), .parakeet)
    }

    func testExplicitParakeetFallsBackToWhisperOnIntel() {
        // CoreML/ANE needs Apple Silicon; Intel falls back to Whisper.
        XCTAssertEqual(EngineSelector.resolve(preference: .parakeet, chipTier: .intel, unifiedMemoryGB: 16), .whisper)
    }

    // MARK: - M11: explicit-Qwen under-gate confirmation

    func testExplicitQwenNeedsConfirmationOnlyForUnderGateQwen() {
        // Under-gate machines with an EXPLICIT qwen choice → needs confirm.
        XCTAssertTrue(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .base, unifiedMemoryGB: 16))
        XCTAssertTrue(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .pro, unifiedMemoryGB: 16))   // strong chip but < 24 GB
        XCTAssertTrue(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .intel, unifiedMemoryGB: 128))
    }

    func testExplicitQwenOnCapableMacNeedsNoConfirmation() {
        // Machines that clear the auto gate → no confirm.
        XCTAssertFalse(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .pro, unifiedMemoryGB: 24))
        XCTAssertFalse(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .max, unifiedMemoryGB: 32))
        XCTAssertFalse(EngineSelector.explicitQwenNeedsConfirmation(
            preference: .qwen, chipTier: .ultra, unifiedMemoryGB: 64))
    }

    func testNonQwenPreferenceNeverNeedsConfirmation() {
        // Nothing to confirm for any non-qwen preference, even on weak hardware.
        for pref: TranscriptionEngine in [.auto, .whisper, .parakeet] {
            XCTAssertFalse(EngineSelector.explicitQwenNeedsConfirmation(
                preference: pref, chipTier: .base, unifiedMemoryGB: 8),
                "\(pref) should never require the Qwen confirm")
            XCTAssertFalse(EngineSelector.explicitQwenNeedsConfirmation(
                preference: pref, chipTier: .intel, unifiedMemoryGB: 128))
        }
    }

    // MARK: - Package C: configurable backup / fallback engine resolution

    /// A distinct backup preference resolves to that concrete engine — NOT the
    /// hardcoded Whisper. This is the whole point of Package C: given
    /// `fallbackEngine == "qwen"`, the constructed fallback must be Qwen.
    func testFallbackResolvesToConfiguredEngine() {
        // Primary Parakeet, backup Qwen → fallback is Qwen (a capable Mac).
        XCTAssertEqual(
            EngineSelector.resolveFallback(
                primaryPreference: .parakeet, fallbackPreference: .qwen,
                chipTier: .max, unifiedMemoryGB: 32),
            .qwen)
        // Primary Qwen, backup Whisper → fallback is Whisper (the classic case).
        XCTAssertEqual(
            EngineSelector.resolveFallback(
                primaryPreference: .qwen, fallbackPreference: .whisper,
                chipTier: .max, unifiedMemoryGB: 32),
            .whisper)
    }

    /// When the resolved backup equals the resolved primary, there is no distinct
    /// fallback — return `nil` rather than wiring a pointless self-fallback.
    func testFallbackEqualToPrimaryIsNil() {
        // Same explicit engine on both sides.
        XCTAssertNil(EngineSelector.resolveFallback(
            primaryPreference: .whisper, fallbackPreference: .whisper,
            chipTier: .max, unifiedMemoryGB: 32))
        // Different *preferences* that resolve to the same concrete engine:
        // `.auto` on Apple Silicon resolves to Parakeet, so an explicit Parakeet
        // backup is the same concrete engine → nil.
        XCTAssertNil(EngineSelector.resolveFallback(
            primaryPreference: .auto, fallbackPreference: .parakeet,
            chipTier: .pro, unifiedMemoryGB: 24))
        // On Intel both `.auto` and `.parakeet` resolve to Whisper → nil.
        XCTAssertNil(EngineSelector.resolveFallback(
            primaryPreference: .parakeet, fallbackPreference: .whisper,
            chipTier: .intel, unifiedMemoryGB: 16))
    }

    /// The resolver honours hardware capability for the backup too: an explicit
    /// Parakeet backup on Intel resolves to Whisper (Parakeet needs Apple Silicon),
    /// which — against a Qwen primary — is a real distinct fallback.
    func testFallbackHonoursHardwareCapability() {
        XCTAssertEqual(
            EngineSelector.resolveFallback(
                primaryPreference: .qwen, fallbackPreference: .parakeet,
                chipTier: .intel, unifiedMemoryGB: 16),
            .whisper)   // Parakeet→Whisper on Intel; distinct from the Qwen primary
    }

    // MARK: - enum plumbing

    func testTranscriptionEngineRawValuesStable() {
        // These strings are persisted in Settings; keep them stable.
        XCTAssertEqual(TranscriptionEngine.auto.rawValue, "auto")
        XCTAssertEqual(TranscriptionEngine.whisper.rawValue, "whisper")
        XCTAssertEqual(TranscriptionEngine.qwen.rawValue, "qwen")
        XCTAssertEqual(TranscriptionEngine.parakeet.rawValue, "parakeet")
        XCTAssertEqual(TranscriptionEngine(rawValue: "qwen"), .qwen)
        XCTAssertEqual(TranscriptionEngine(rawValue: "parakeet"), .parakeet)
        XCTAssertNil(TranscriptionEngine(rawValue: "bogus"))
    }
}
