import Foundation

// MARK: - NextStepSuggestion

/// Pure, testable decision logic for the Shows pane's persistent „Nächster
/// Schritt"-Leiste (next-best-action bar) — post-subscribe-nba brief §2.
///
/// The bar invites the user to transcribe every pending episode in one tap. It
/// is shown whenever there is unprocessed work AND the queue isn't already
/// doing that work AND the user hasn't already dismissed THIS exact batch.
///
/// „Pending" here means episodes in the literal `pending` status — NOT
/// `deferred` (wave-1 safe-by-default semantics: a `deferred` episode was
/// deliberately held back because auto-download is off for its show, and
/// showing a bar that says "ready to transcribe" for those would contradict
/// that choice). Callers supply a dedicated literal-`pending` count/newest-date
/// pair (see `StateReader.pendingSummary()`), not the broader "not done, not
/// failed" count `ShowsViewModel.ShowItem.pendingCount` uses for its own badge.
public enum NextStepSuggestion {

    /// The bar's visibility + content, as decided by `compute`.
    public enum BarState: Equatable {
        case hidden
        /// - Parameters:
        ///   - pendingCount: Episodes in literal `pending` status, globally.
        ///   - etaMinutes: Estimated total minutes to transcribe all of them,
        ///     when computable from the queue's own Ø/episode figure; `nil`
        ///     omits the ETA suffix entirely (no new estimator is built here).
        case visible(pendingCount: Int, etaMinutes: Int?)
    }

    /// Builds a stable fingerprint for a `(pendingCount, pendingNewestAt)` pair
    /// so a dismissal can be scoped to "this exact batch" — a new episode
    /// arriving later changes either figure, produces a new fingerprint, and
    /// un-hides the bar even though the user dismissed an earlier batch.
    ///
    /// `pendingNewestAt` is folded in (not just the count) so that one episode
    /// finishing while another arrives — a wash that leaves the count
    /// unchanged — still counts as a new batch.
    public static func fingerprint(pendingCount: Int, pendingNewestAt: String?) -> String {
        "\(pendingCount)|\(pendingNewestAt ?? "")"
    }

    /// Decides whether the bar should show, and with what content.
    ///
    /// Visible iff: `pendingCount > 0 && !queueRunning &&`
    /// `fingerprint(pendingCount, pendingNewestAt) != dismissedFingerprint`.
    ///
    /// - Parameters:
    ///   - pendingCount: Global count of literal-`pending` episodes.
    ///   - pendingNewestAt: The newest `pub_date` among those pending episodes
    ///     (ISO string), or `nil` when unknown/`pendingCount == 0`. Only used
    ///     to build the fingerprint — never shown directly.
    ///   - dismissedFingerprint: The fingerprint the user last dismissed (from
    ///     persistent storage), or `nil` if nothing has ever been dismissed.
    ///   - queueRunning: `true` while the queue is actively processing — the
    ///     bar's own CTA would be redundant (the work is already happening).
    ///   - etaMinutes: Passed straight through to `.visible` when computable;
    ///     see `BarState.visible`.
    /// - Returns: `.hidden` or `.visible(pendingCount:etaMinutes:)`.
    public static func compute(
        pendingCount: Int,
        pendingNewestAt: String?,
        dismissedFingerprint: String?,
        queueRunning: Bool,
        etaMinutes: Int? = nil
    ) -> BarState {
        guard pendingCount > 0, !queueRunning else { return .hidden }
        let current = fingerprint(pendingCount: pendingCount, pendingNewestAt: pendingNewestAt)
        guard current != dismissedFingerprint else { return .hidden }
        return .visible(pendingCount: pendingCount, etaMinutes: etaMinutes)
    }

    /// Converts the queue's own per-episode seconds estimate into the whole-run
    /// minutes figure the bar's „(≈ %lld Min)" suffix shows — the ONE seconds→
    /// minutes conversion this feature needs (UX Wave 7 §1: reuse the queue's
    /// existing Ø/episode estimator, don't build a second one).
    ///
    /// - Parameters:
    ///   - avgSecondsPerEpisode: `QueueController.avgSecondsPerEpisode` — `nil`
    ///     before any episode has completed (or a live in-flight estimate
    ///     exists), in which case this returns `nil` (no ETA shown yet).
    ///   - pendingCount: The same literal-`pending` count passed to `compute`.
    /// - Returns: The total estimated minutes, rounded to the nearest minute
    ///   (never zero for a non-zero estimate — at least 1 minute is shown so
    ///   "(≈ 0 Min)" never appears for a short-but-nonzero remaining run).
    public static func estimatedTotalMinutes(avgSecondsPerEpisode: Double?, pendingCount: Int) -> Int? {
        guard let avg = avgSecondsPerEpisode, avg > 0, pendingCount > 0 else { return nil }
        let totalSeconds = avg * Double(pendingCount)
        return max(1, Int((totalSeconds / 60).rounded()))
    }
}
