import Foundation

/// Which visible region of the queue an episode belongs to.
public enum QueueLane: String, Sendable, Equatable {
    case nowTranscribing   // in-flight worker
    case upNext            // pending, priority > 0 (curated, reorderable, drains first)
    case comingUp          // pending, priority == 0 (backlog: new episodes + backfill)

    /// Derive the lane from the raw episode `status` + `priority`.
    public static func of(status: String, priority: Int) -> QueueLane {
        switch status {
        case "downloading", "transcribing":
            return .nowTranscribing
        case "pending":
            return priority > 0 ? .upNext : .comingUp
        default:
            return .comingUp
        }
    }
}

/// Where a batch lands when added to Up Next.
public enum UpNextPosition: Sendable, Equatable { case top, bottom }

/// Pure rank math for Up Next. Up Next uses dense descending integer priorities
/// in a fixed positive band, so ranks never collide with Coming-up (`0`). The band
/// sits below the legacy `enqueueFront` timestamp scheme (~1.7e9), so a fresh
/// front-enqueue sorts to the very top until an explicit reorder re-ranks the list.
public enum UpNextRanker {
    public static let base = 1_000_000

    /// Descending priorities for `count` items, top-first: `[base+count-1, …, base]`.
    public static func rank(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0..<count).map { base + (count - 1 - $0) }
    }
}
