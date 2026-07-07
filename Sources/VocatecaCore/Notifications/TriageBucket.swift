import Foundation

// MARK: - TriageBucket

/// Actionability segments for the Notifications triage inbox.
///
/// Replaces the old *type* filters (Episodes / Account / Keywords / System) with
/// a "what needs me" model. Lives in `VocatecaCore` (no SwiftUI/AppKit import) so
/// the kind→bucket mapping is a plain, unit-testable switch shared by the UI.
///
/// The order of the cases is the order the segments appear in the UI, and
/// `needsAction` is the default segment.
public enum TriageBucket: String, CaseIterable, Sendable {
    /// Unresolved items that require the user to act:
    /// `failure`, `skippedNoSpeech`, `accountReauth`, `accountSuspended`.
    case needsAction
    /// Unresolved/unread informational items worth a look: `newEpisode`, `keywordHit`.
    case new
    /// Purely informational kinds, **plus** any item the user has resolved
    /// (acted on) out of `needsAction` / `new`.
    case done

    /// Localisation key for the segment label. Reuses existing `.strings` keys
    /// where possible ("New", "Done"); only "Needs action" is new.
    public var localizationKey: String {
        switch self {
        case .needsAction: return "Needs action"
        case .new:         return "New"
        case .done:        return "Done"
        }
    }
}

// MARK: - NotifKindKey → base bucket

public extension NotifKindKey {

    /// The bucket a kind falls into **before** the resolved flag is considered.
    ///
    /// This is a pure classification of the *kind*: informational kinds map to
    /// `.done`; actionable kinds map to `.needsAction` or `.new`. The UI layer
    /// then overrides any resolved item into `.done` (see ``triageBucket(isResolved:)``).
    var baseTriageBucket: TriageBucket {
        switch self {
        // Needs action — the user must intervene.
        case .failure, .skippedNoSpeech, .accountReauth, .accountSuspended:
            return .needsAction
        // New — unread informational the user may want to act on.
        case .newEpisode, .keywordHit:
            return .new
        // Done — purely informational / summaries.
        case .runFinished, .backfillDone, .dailySummary, .modelReady,
             .storageWarning, .mediaEvicted:
            return .done
        }
    }

    /// The effective triage bucket, accounting for the resolved flag.
    ///
    /// Once an item is resolved (the user acted on it — Retry / Transcribe now /
    /// Ignore / Transcribe anyway), it drops out of `.needsAction` / `.new` and
    /// surfaces under `.done`, regardless of its kind.
    ///
    /// - Parameter isResolved: Whether the user has acted on / resolved the item.
    func triageBucket(isResolved: Bool) -> TriageBucket {
        if isResolved { return .done }
        return baseTriageBucket
    }
}
