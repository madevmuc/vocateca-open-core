import Foundation

// MARK: - WatchlistFileCoordinator

/// Single serial write path for `watchlist.yaml` (M9 — read-modify-write race).
///
/// ## The race this closes
/// `WatchlistStore`'s mutators (``WatchlistStore/updateAuthor(slug:author:to:)``
/// etc., plus ``WatchlistStore/add(_:)``/``WatchlistStore/remove(slug:)``) each
/// follow the shape `load → mutate in memory → save`. Every call site —
/// `FeedIngestor` author-backfill, `IngestCoordinator` metadata-refresh, every
/// Shows/Settings UI edit, and every `vocateca-cli sources` subcommand — loads
/// its OWN snapshot, mutates it, and saves. Two concurrent writers each working
/// from a stale snapshot silently clobber each other: last save wins, the
/// other edit is lost with no error.
///
/// ## Design: one coordinated read-modify-write transaction
/// `NSFileCoordinator` is a system service (`filecoordinationd`) — coordinated
/// accessors to the same file URL are serialised against EVERY other
/// coordinated accessor to that URL, from any thread, in any process on the
/// machine. That is exactly the "one serial write path" M9 asks for, and it is
/// the only mechanism that also covers `vocateca-cli`: a CLI invocation is a
/// separate OS process with no way to share an in-process lock/actor with the
/// running app, but it shares the SAME file coordinator claim space.
///
/// ``perform(url:_:)`` wraps a coordinated READ (of the freshest on-disk copy)
/// and the subsequent WRITE as one atomic-with-respect-to-other-coordinators
/// transaction — closing the read-mutate-save race, not just serialising the
/// final `saveAtomic` call (a plain "lock only the write" fix would still let
/// two callers both read a stale copy, then take turns clobbering each other).
/// ``WatchlistStore`` routes every mutator through this so the actual on-disk
/// merge always starts from the latest state, never a possibly-superseded
/// in-memory snapshot.
///
/// ## No deadlock
/// `NSFileCoordinator.coordinate(readingItemAt:writingItemAt:...)` runs its
/// accessor closure SYNCHRONOUSLY on the calling thread — it is not
/// reentrant-safe to invoke it again from inside that closure for the SAME
/// URL (that would deadlock waiting on a claim the outer call already holds).
/// `perform(url:_:)` is therefore a non-reentrant leaf: `body` must never call
/// back into `WatchlistFileCoordinator` for the same watchlist URL. Every
/// caller in this codebase satisfies this — `WatchlistStore`'s mutator bodies
/// only touch the in-memory `Watchlist` value handed to them, never re-enter
/// the coordinator.
public enum WatchlistFileCoordinator {

    /// Performs `body` as ONE coordinated read+write transaction against `url`.
    ///
    /// `body` receives the freshest on-disk ``Watchlist`` (never a possibly-stale
    /// in-memory copy) and returns the value to persist plus a result to hand
    /// back to the caller. Returning `nil` for the watchlist-to-write skips the
    /// save entirely (read-only use, or "no change needed") without giving up
    /// the coordinated read.
    ///
    /// - Throws: Whatever `body` throws, a coordination error (e.g. a sandbox
    ///   denial), or a ``Watchlist/saveAtomic(to:)`` error.
    public static func perform<T>(
        url: URL,
        _ body: (Watchlist) throws -> (write: Watchlist?, result: T)
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var thrown: Error?
        var output: T?

        coordinator.coordinate(
            readingItemAt: url, options: [],
            writingItemAt: url, options: [.forReplacing],
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                let current = try Watchlist.load(from: readURL)
                let (toWrite, result) = try body(current)
                if let toWrite {
                    try toWrite.saveAtomic(to: writeURL)
                }
                output = result
            } catch {
                thrown = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        guard let output else {
            // Unreachable in practice — `coordinate`'s accessor always runs
            // synchronously before returning when there's no coordination
            // error — but fail loudly rather than silently return a bogus
            // default if that contract ever changes.
            throw WatchlistFileCoordinatorError.accessorDidNotRun
        }
        return output
    }

    /// Coordinated read-only load — guards against observing a half-written
    /// file mid-rename from a concurrent (possibly cross-process) writer.
    public static func read(url: URL) throws -> Watchlist {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var thrown: Error?
        var output: Watchlist?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                output = try Watchlist.load(from: readURL)
            } catch {
                thrown = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        return output ?? Watchlist()
    }
}

enum WatchlistFileCoordinatorError: Error {
    case accessorDidNotRun
}
