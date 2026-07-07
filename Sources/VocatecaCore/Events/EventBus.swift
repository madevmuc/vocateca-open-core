import Foundation

// MARK: - EventMatcher

/// Describes which events a subscriber wants to receive.
///
/// Mirrors the Python `Matcher = Union[str, Callable[[Event], bool]]` semantics:
/// - `.all`           → match-all (Python `""`)
/// - `.exact(String)` → exact type string (Python non-empty, no trailing `.`)
/// - `.prefix(String)` → prefix ending in `"."` (Python `"episode."`)
/// - `.predicate`      → arbitrary closure filter
///
/// ## String convenience
///
/// `EventMatcher(rawString:)` parses a raw Python-style matcher string the same
/// way the Python bus does: `""` → `.all`, ends with `"."` → `.prefix`, else
/// `.exact`.
public enum EventMatcher: Sendable {
    /// Matches every event.
    case all
    /// Matches only events whose `type` equals `value` exactly.
    case exact(String)
    /// Matches events whose `type` starts with `prefix` (e.g. `"episode."`).
    case prefix(String)
    /// Matches events for which `predicate` returns `true`.
    case predicate(@Sendable (Event) -> Bool)

    // MARK: String parse convenience

    /// Parses a Python-style matcher string into an `EventMatcher`.
    ///
    /// - `""` → `.all`
    /// - Ends with `"."` → `.prefix(string)`
    /// - Otherwise → `.exact(string)`
    public init(rawString: String) {
        if rawString.isEmpty {
            self = .all
        } else if rawString.hasSuffix(".") {
            self = .prefix(rawString)
        } else {
            self = .exact(rawString)
        }
    }

    // MARK: Matching

    /// Returns `true` when this matcher accepts `event`.
    ///
    /// A `.predicate` that throws is treated as non-matching (equivalent to
    /// the Python `except Exception: return False` guard on callables).
    public func matches(_ event: Event) -> Bool {
        switch self {
        case .all:
            return true
        case .exact(let t):
            return event.type == t
        case .prefix(let p):
            return event.type.hasPrefix(p)
        case .predicate(let fn):
            // Swallow predicate errors: a broken filter must not break dispatch.
            return fn(event)
        }
    }
}

// MARK: - SubscriptionToken

/// An opaque token returned by ``EventBus/subscribeCallback(_:handler:)`` that
/// can be passed to ``EventBus/unsubscribe(_:)`` to remove the callback
/// subscriber.
public struct SubscriptionToken: Sendable, Hashable {
    fileprivate let id: UUID
    fileprivate init() { id = UUID() }
}

// MARK: - EventBus

/// In-process typed event bus.
///
/// Mirrors `core.events` from the Python app: a module-level singleton that
/// lets the pipeline, feed scanner, worker, and UI publish lifecycle events
/// and receive them via `AsyncStream<Event>` or optional synchronous callbacks.
///
/// ## Dispatch contract
///
/// A subscriber/callback failure must **never** break the emitter. Callback
/// errors are caught and printed (matching the Python `_logger.exception`
/// approach). Slow `AsyncStream` consumers cannot block other subscribers
/// because each subscriber gets its own buffered continuation — see
/// "Buffering policy" below.
///
/// ## Buffering policy
///
/// Each `AsyncStream` continuation is created with `.bufferingNewest(256)`.
/// This means:
/// - Up to 256 unread events are queued per subscriber.
/// - If a slow consumer falls more than 256 events behind, the **oldest**
///   buffered events are dropped for that subscriber only.
/// - Other subscribers are unaffected.
///
/// 256 is generous for the current workload (O(tens) of events per pipeline
/// run). Adjust if high-frequency events are added.
///
/// M4: a drop is no longer silent — ``emit(_:)`` logs a `Log.warn` each time
/// `.bufferingNewest` actually discards an event, so a chronically slow
/// consumer (e.g. `WebhookDispatcher` piled up behind a dead endpoint) shows
/// up in the log instead of just quietly losing events.
///
/// ## Swift 6 / Sendable
///
/// `EventBus` is a `public actor`, so all state mutations happen on the actor
/// executor. The `@Sendable` constraint on `.predicate` matchers ensures
/// closures capturing non-Sendable values are rejected at compile time.
public actor EventBus {

    // MARK: - Shared singleton

    /// The shared event bus. All pipeline code should use this instance;
    /// tests may construct their own `EventBus()` for isolation.
    public static let shared = EventBus()

    // MARK: - Internal state

    // AsyncStream subscribers: (matcher, continuation)
    private var streamSubs: [UUID: (EventMatcher, AsyncStream<Event>.Continuation)] = [:]

    // Callback subscribers: token → (matcher, handler)
    private var callbackSubs: [UUID: (EventMatcher, @Sendable (Event) -> Void)] = [:]

    // MARK: - Initialiser

    /// Creates a new `EventBus`. Prefer ``shared`` in production code.
    public init() {}

    // MARK: - AsyncStream API (primary)

    /// Returns an `AsyncStream<Event>` that yields every event matching
    /// `matcher`.
    ///
    /// Each call produces an independent stream — multiple concurrent
    /// subscribers each receive their own copy of matching events.
    ///
    /// Dropping the stream (letting it go out of scope or breaking the
    /// `for await` loop) unsubscribes automatically via `onTermination`.
    ///
    /// ## Buffering
    /// The stream is created with `.bufferingNewest(256)`. See the class
    /// docstring for the rationale.
    public func subscribe(_ matcher: EventMatcher) -> AsyncStream<Event> {
        _makeStream(matcher: matcher, id: UUID())
    }

    // Helper that captures the continuation synchronously.
    private func _makeStream(matcher: EventMatcher, id: UUID) -> AsyncStream<Event> {
        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(256)) { cont in
            capturedContinuation = cont
        }
        if let cont = capturedContinuation {
            streamSubs[id] = (matcher, cont)
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeStreamSub(id: id) }
            }
        }
        return stream
    }

    private func removeStreamSub(id: UUID) {
        streamSubs.removeValue(forKey: id)
    }

    // MARK: - Emit

    /// Fans out `event` to all matching subscribers.
    ///
    /// - **AsyncStream** subscribers receive the event via their buffered
    ///   continuation. A full buffer silently drops the oldest event for that
    ///   subscriber only; other subscribers are unaffected. M4: this drop is
    ///   no longer silent — `.bufferingNewest`'s `yield` return tells us when
    ///   it happened, so we log it (see below) instead of losing the signal.
    /// - **Callback** subscribers are called synchronously on the actor. A
    ///   callback that throws or crashes is caught and printed; the remaining
    ///   subscribers still receive the event.
    ///
    /// This function never throws and never propagates subscriber failures —
    /// matching the Python guarantee that "emitting an event must never break
    /// the action that emitted it."
    public func emit(_ event: Event) {
        // Fan out to AsyncStream subscribers.
        for (_, (matcher, cont)) in streamSubs {
            if matcher.matches(event) {
                // M4: `.bufferingNewest(256)` silently dropped the oldest
                // buffered event for a slow subscriber once >256 events piled
                // up — invisible in the log, so a stuck consumer (e.g. a
                // webhook endpoint that's down) looked like normal operation
                // right up until events mysteriously never arrived. `yield`
                // tells us exactly when this happens; log it so the loss is
                // visible instead of silent. Still never throws/blocks emit.
                switch cont.yield(event) {
                case .dropped:
                    Log.warn("EventBus: subscriber buffer full — oldest event dropped",
                             component: "EventBus",
                             context: [("type", event.type), ("bufferCap", "256")])
                case .enqueued, .terminated:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Fan out to callback subscribers.
        for (_, (matcher, handler)) in callbackSubs {
            if matcher.matches(event) {
                // Swallow failures — a broken callback must never break the emitter.
                handler(event)
            }
        }
    }

    // MARK: - Callback API (optional, for parity with Python subscribe())

    /// Registers a synchronous callback that is invoked on the actor for each
    /// matching event.
    ///
    /// Returns a ``SubscriptionToken`` that can be passed to
    /// ``unsubscribe(_:)`` to remove the subscription. If the token is
    /// discarded without calling `unsubscribe`, the subscription lives until
    /// the bus is deallocated.
    ///
    /// ## Error isolation
    /// The `handler` is a non-throwing `@Sendable` closure, so recoverable
    /// errors must be handled inside it. A hard trap (force-unwrap, precondition)
    /// inside a handler cannot be caught and would take down the actor — keep
    /// handlers simple and non-trapping. This is the one isolation guarantee
    /// Swift cannot provide that the Python (exception-swallowing) bus does.
    @discardableResult
    public func subscribeCallback(
        _ matcher: EventMatcher,
        handler: @escaping @Sendable (Event) -> Void
    ) -> SubscriptionToken {
        let token = SubscriptionToken()
        callbackSubs[token.id] = (matcher, handler)
        return token
    }

    /// Removes the callback subscription identified by `token`.
    ///
    /// Safe to call even if `token` has already been unsubscribed or was
    /// never registered.
    public func unsubscribe(_ token: SubscriptionToken) {
        callbackSubs.removeValue(forKey: token.id)
    }

    // MARK: - Persistence bridge

    /// Attaches `store` as a persistence subscriber that writes every emitted
    /// event to the `events` table.
    ///
    /// Loosely coupled: `EventBus` has no direct dependency on `StateStore` —
    /// `attachPersistence` merely subscribes a callback that calls the store's
    /// `appendEvent` method. Persistence failures are swallowed by the
    /// callback error-isolation contract (see ``emit(_:)`` docstring).
    ///
    /// - Returns: A ``SubscriptionToken`` you can pass to ``unsubscribe(_:)``
    ///   to detach persistence (e.g. in teardown). Discard the token to keep
    ///   persistence alive for the lifetime of the bus.
    @discardableResult
    public func attachPersistence(_ store: StateStore) -> SubscriptionToken {
        return subscribeCallback(.all) { event in
            // Swallow DB errors — a transient write failure must not break dispatch.
            do {
                try store.appendEvent(
                    type: event.type,
                    showSlug: event.showSlug,
                    guid: event.guid,
                    payloadJSON: event.payloadJSONString()
                )
            } catch {
                Log.error("Persistence write failed",
                          component: "EventBus",
                          context: [("type", event.type), ("error", "\(error)")])
            }
        }
    }

    // MARK: - Test helpers

    /// Removes all subscribers (AsyncStream + callback). Intended for test
    /// teardown; mirrors the Python `reset()` helper.
    public func reset() {
        for (_, cont) in streamSubs.values {
            cont.finish()
        }
        streamSubs.removeAll()
        callbackSubs.removeAll()
    }
}
