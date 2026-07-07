import Foundation

// MARK: - Timeout util (H6)
//
// Shared cooperative-cancellation timeout for long-running async work whose
// underlying API exposes no timeout of its own — most importantly the three
// transcription engines' lazy model load/download (WhisperKit `loadedBox`,
// `QwenTranscriber.loadedModel`, `ParakeetTranscriber.loadedManager`). A
// stalled first download (network black-hole after the TCP handshake) otherwise
// never returns and pins the episode in `transcribing` forever — see finding H6
// in docs/design/audit-v2-2026-07-05.md.
//
// Hoisted here (Foundation-only, no AppKit/SwiftUI) from the private copy that
// lived in the now-dead `Engines/WhisperKitTranscriptionEngine.swift` transcribe
// path so all three engines share ONE implementation.

/// Thrown by ``withTimeout(seconds:operation:)`` when `operation` does not
/// finish within the deadline. Callers should treat this as **transient /
/// retryable** (a requeue), never a permanent failure: a model download can
/// stall on a flaky network and succeed on the next attempt. Carries the
/// elapsed seconds purely for diagnostics.
public struct TimeoutError: Error, Sendable, CustomStringConvertible {
    /// The deadline that elapsed, in seconds.
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public var description: String {
        "operation timed out after \(String(format: "%.0f", seconds))s"
    }
}

/// Runs `operation`, throwing ``TimeoutError`` if it has not completed within
/// `seconds`. Implemented as a race between the operation and a sleep task in a
/// throwing task group; whichever finishes first wins and the other is
/// cancelled. Cancellation is cooperative — `operation` must observe
/// `Task.isCancelled` / `try Task.checkCancellation()` (or await something that
/// does) for the losing branch to actually stop; the timeout still fires and
/// unblocks the caller regardless, which is the point for a wedged model load.
///
/// - Parameters:
///   - seconds: The deadline. A non-positive value disables the timeout
///     (the operation runs to completion) — defensive, so a misconfigured 0
///     never instantly fails every load.
///   - operation: The async work to bound.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // A non-positive deadline means "no timeout" — just run it.
    guard seconds > 0 else { return try await operation() }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        // The first task to finish (or throw) wins; cancel the loser.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Model-load timeout constant

/// Deadline for a cold engine's one-time model load/download (H6). Generous
/// enough for a first multi-GB fetch on a slow connection, short enough that a
/// genuinely wedged download surfaces as a retryable error within one queue
/// cycle instead of hanging `transcribing` indefinitely.
public let modelLoadTimeoutSeconds: Double = 10 * 60
