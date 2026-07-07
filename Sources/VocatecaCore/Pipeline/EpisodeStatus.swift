import Foundation

// MARK: - EpisodeStatus

/// The lifecycle states an episode can occupy. The first ten mirror Python's
/// `core.state.EpisodeStatus` enum exactly (raw values are the strings stored
/// in the `episodes.status` column).
///
/// `deleted` is a **Swift-only** addition with no Python counterpart: it marks
/// an episode whose transcript the user explicitly deleted from disk (see
/// `StateStore.clearTranscriptAndMarkDeleted(guid:)`). It shares `skipped`'s
/// *processing* semantics — excluded from the queue, never auto-processed (all
/// queue selection keys on `status = 'pending'`, so `deleted` is skipped just
/// like `skipped`) — but is displayed as a neutral "Deleted" rather than a
/// failure. It is written via a dedicated SQL update, never `setStatus(_:)`, so
/// it deliberately emits no lifecycle event.
///
/// Statuses absent from `_STATUS_EVENT_MAP` — `pending`, `stale`, `paused`,
/// plus the Swift-only `deleted` — emit no lifecycle event when set. All others
/// trigger a matched event via `StateStore.setStatus(_:_:errorText:)`.
public enum EpisodeStatus: String, Sendable, Codable, CaseIterable {
    case pending     = "pending"
    case downloading = "downloading"
    case downloaded  = "downloaded"
    case transcribing = "transcribing"
    case done        = "done"
    case failed      = "failed"
    case stale       = "stale"
    case skipped     = "skipped"
    case deferred    = "deferred"
    case paused      = "paused"
    /// Swift-only: transcript explicitly deleted by the user. Same queue/
    /// processing semantics as `skipped`; displayed as neutral "Deleted".
    case deleted     = "deleted"
}

// MARK: - Status → EventType mapping

extension EpisodeStatus {
    /// Returns the ``EventType`` string that should be emitted when an episode
    /// transitions into this status, or `nil` when the status emits no event.
    ///
    /// Mirrors Python's `_STATUS_EVENT_MAP` in `core/state.py`:
    ///
    /// | Status        | EventType                       |
    /// |---------------|---------------------------------|
    /// | downloading   | episode.download_started        |
    /// | downloaded    | episode.downloaded              |
    /// | transcribing  | episode.transcribe_started      |
    /// | done          | episode.transcribed             |
    /// | failed        | episode.failed                  |
    /// | skipped       | episode.skipped                 |
    /// | deferred      | episode.deferred                |
    /// | pending/stale/paused | (none — no event)        |
    public var lifecycleEventType: String? {
        switch self {
        case .downloading:  return EventType.episodeDownloadStarted
        case .downloaded:   return EventType.episodeDownloaded
        case .transcribing: return EventType.episodeTranscribeStarted
        case .done:         return EventType.episodeTranscribed
        case .failed:       return EventType.episodeFailed
        case .skipped:      return EventType.episodeSkipped
        case .deferred:     return EventType.episodeDeferred
        case .pending, .stale, .paused, .deleted:
            // `.deleted` is Swift-only and written via a dedicated SQL update
            // (never `setStatus(_:)`), so it emits no lifecycle event — grouped
            // here with the other event-less statuses.
            return nil
        }
    }
}
