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
        continuation.yield(event)
    }

    /// Ends the consumer task. Called when the owning pipeline is torn down; safe
    /// to call more than once.
    func finish() {
        continuation.finish()
    }

    // Buffer generously — a run emits O(tens) of events; unbounded avoids ever
    // dropping an ordering-critical progress event under load.
    private static func makeStream() -> (AsyncStream<Event>, AsyncStream<Event>.Continuation) {
        var captured: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { captured = $0 }
        return (stream, captured)
    }
}
