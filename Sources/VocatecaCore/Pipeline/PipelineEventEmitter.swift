import Foundation

// MARK: - PipelineEventEmitter
//
// L3 — Event-emission ordering.
//
// The pipeline emits several `episode.progress` / lifecycle events per episode.
// Previously each was fired as its own detached `Task { await bus.emit(event) }`.
// Independent tasks have NO ordering guarantee when they hop onto the EventBus
// actor: an event emitted earlier in source order can be delivered AFTER one
// emitted later, so a subscriber (e.g. QueueRunner's progress handler) can see
// fraction 0.30 then 0.12 — the progress bar jumps backwards.
//
// This emitter serialises emission through a single ordered channel: producers
// call the synchronous `emit(_:)`, which `yield`s onto an `AsyncStream`
// continuation (ordering-preserving, non-blocking), and ONE consumer task awaits
// the stream and calls `bus.emit` in the exact order the events were produced.
// The producer side stays fire-and-forget (no `await` at the call site), so the
// download/transcribe hot path is not made async on the bus — only the ordering
// is fixed.
//
// Ordering guarantee is per-emitter. The pipeline owns one emitter, shared across
// the concurrent episodes it processes, so the global emission order is a single
// well-defined FIFO — strictly stronger than the old per-event race.
final class PipelineEventEmitter: Sendable {

    private let continuation: AsyncStream<Event>.Continuation

    /// Creates an emitter that forwards every `emit`ted event, in order, to `bus`.
    /// Spawns a single long-lived consumer task; it ends when `finish()` is called
    /// or the emitter is deallocated.
    init(bus: EventBus) {
        let (stream, cont) = Self.makeStream()
        self.continuation = cont
        // Single ordered consumer: preserves the producer's FIFO order because an
        // AsyncStream delivers yielded elements in order to its single iterator.
        Task {
            for await event in stream {
                await bus.emit(event)
            }
        }
    }

    /// Enqueues `event` for ordered delivery. Synchronous + non-blocking: the
    /// caller does not await the bus. Order is preserved relative to other `emit`
    /// calls on the same emitter.
    func emit(_ event: Event) {
        switch continuation.yield(event) {
        case .dropped:
            Log.warn("Pipeline emitter buffer full — oldest event dropped (consumer starved)",
                     component: "Pipeline",
                     context: [("type", event.type), ("bufferCap", String(Self.bufferCap))])
        case .enqueued, .terminated:
            break
        @unknown default:
            break
        }
    }

    /// Ends the consumer task. Called when the owning pipeline is torn down; safe
    /// to call more than once.
    func finish() {
        continuation.finish()
    }

    /// Backstop against unbounded growth.
    ///
    /// This buffer was `.unbounded`, justified by "a run emits O(tens) of events".
    /// That was wrong: WhisperKit fires its progress callback once per decoded
    /// token, so a long episode produced O(10^4–10^5) progress events. When the
    /// consumer task below was starved — the cooperative pool saturated by the
    /// decode itself plus WhisperKit's per-token `Task.detached` callbacks — the
    /// queue never drained and grew until the app was killed for memory
    /// (2026-07-16, tens of GB resident). `ProgressThrottle` now caps the
    /// producer rate at a few events/second, which alone keeps this buffer
    /// shallow; the bound here exists so a future high-frequency producer costs
    /// bounded memory instead of the whole machine.
    ///
    /// Dropping is survivable: `QueueRunner` reconciles item status against the
    /// DB independently of the bus, so a lost event costs at most a late UI
    /// refresh — strictly better than an OOM kill. Drops are logged, never silent.
    private static let bufferCap = 512

    private static func makeStream() -> (AsyncStream<Event>, AsyncStream<Event>.Continuation) {
        var captured: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(bufferCap)) { captured = $0 }
        return (stream, captured)
    }
}
