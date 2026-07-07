import Foundation

// MARK: - EnumerationResult

/// The result of one incremental enumeration pass for an Instagram profile.
public struct EnumerationResult: Sendable, Equatable {
    /// Items that are genuinely new (not in `knownShortcodes`, above the cursor).
    public let newItems: [GalleryDLItem]
    /// Shortcodes that were in `knownShortcodes` *within the fresh window* but
    /// absent from the current listing — indicating deletion or unavailability.
    public let deletedShortcodes: [String]
    /// The shortcode of the **newest** item seen in this pass. Becomes the new
    /// cursor for the next enumeration. `nil` when the profile has no items.
    public let newCursor: String?

    public init(newItems: [GalleryDLItem], deletedShortcodes: [String], newCursor: String?) {
        self.newItems = newItems
        self.deletedShortcodes = deletedShortcodes
        self.newCursor = newCursor
    }
}

// MARK: - InstagramEnumerator

/// Pure incremental enumeration logic for an Instagram profile.
///
/// ## Incremental algorithm
///
/// gallery-dl returns items **newest-first**. The `cursor` is the shortcode of the
/// newest item we processed in the previous run. On each call:
///
/// 1. Walk the fresh listing (newest→oldest).
/// 2. Stop *after* encountering the cursor shortcode (cursor item itself is not a
///    new item — it was already processed). This defines the **fresh window**: all
///    items at positions [0 …< cursor_index] in the listing.
/// 3. Items in the fresh window whose shortcode is NOT in `knownShortcodes` →
///    `newItems`.
/// 4. The newest item's shortcode (listing[0]) becomes `newCursor`.
///
/// On **first run** (`cursor == nil`): the whole listing is the fresh window.
/// All items not in `knownShortcodes` are returned as `newItems`.
///
/// When the cursor is the newest item (nothing new): `newItems` is empty,
/// `newCursor` equals the old cursor.
///
/// ## Deleted-detection semantics
///
/// **Window definition for deletion:** items are considered "within the window"
/// if their shortcode is in `knownShortcodes` **and** their shortcode would have
/// appeared in the listing between the current cursor and the *previously-seen*
/// shortcode position.
///
/// Practically: we detect deletions **only within the fresh window** (items above
/// the cursor). A known shortcode that falls *below* the cursor (older content) is
/// NOT flagged as deleted — we don't re-scan old pages to check for deletions there.
///
/// **Rationale:** limiting deletion detection to the fresh window avoids
/// re-fetching the entire profile history on each poll. Older deletions are
/// considered out-of-scope for the incremental path (a separate backfill or
/// audit command can detect them explicitly).
///
/// Concretely: for each shortcode in `knownShortcodes` that *would* appear in the
/// fresh window's expected range but is **absent** from the fresh listing, it is
/// added to `deletedShortcodes`. Since we don't know exact positions of known
/// shortcodes on prior listings (we only store the cursor), we use this heuristic:
/// **any known shortcode whose timestamp (if available) is newer than the cursor
/// item's timestamp, or which was seen without a timestamp, is considered within
/// the window**.
///
/// Because timestamps are optional on `GalleryDLItem`, we fall back to a simpler
/// rule when no timestamp is available: we check against the **set of shortcodes
/// present in the fresh listing** above the cursor. Any known shortcode in
/// `knownShortcodes` that is NOT in the fresh window's shortcode set is a deletion
/// candidate **if** the fresh window covers the full profile (i.e., cursor is nil
/// or cursor was reached in this listing). This avoids false positives when the
/// listing is truncated.
///
/// ## Pure / injectable
///
/// This function has no database calls. The caller (pipeline layer) persists
/// `newCursor` via `StateStore` / `persistCursor(…)`.
public enum InstagramEnumerator {

    /// Runs an incremental enumeration pass.
    ///
    /// - Parameters:
    ///   - showSlug: The show slug (used for logging context; not stored here).
    ///   - profile: Instagram handle (passed to `client.enumerate`).
    ///   - knownShortcodes: The set of shortcodes already in the library for this profile.
    ///   - cursor: The shortcode of the last-seen newest item from the previous run,
    ///             or `nil` for a first run.
    ///   - client: The gallery-dl client (injected; `MockGalleryDLClient` in tests).
    /// - Returns: An `EnumerationResult` with new items, deleted shortcodes, and
    ///            the updated cursor.
    public static func enumerate(
        showSlug: String,
        profile: String,
        knownShortcodes: Set<String>,
        cursor: String?,
        client: some GalleryDLClient
    ) async throws -> EnumerationResult {
        let allItems = try await client.enumerate(profile: profile)

        // Edge case: profile has no items at all.
        guard !allItems.isEmpty else {
            return EnumerationResult(newItems: [], deletedShortcodes: [], newCursor: nil)
        }

        // The newest item's shortcode becomes the new cursor.
        let newestShortcode = allItems.first?.shortcode

        // ── Build the fresh window ─────────────────────────────────────────
        // Walk newest→oldest. Stop *after* we encounter the cursor.
        // The cursor item itself is excluded from newItems (already processed).

        var freshWindow: [GalleryDLItem] = []
        var cursorWasFound = false

        for item in allItems {
            if let sc = item.shortcode, sc == cursor {
                // Cursor found — stop here; do NOT include the cursor item.
                cursorWasFound = true
                break
            }
            freshWindow.append(item)
        }
        // If cursor is nil (first run) or cursor wasn't in the listing
        // (e.g., cursor post was deleted), the whole listing is the fresh window.
        // `cursorWasFound` stays false in both cases; `freshWindow` = allItems.

        let freshWindowShortcodes = Set(freshWindow.compactMap { $0.shortcode })

        // ── New items ──────────────────────────────────────────────────────
        let newItems = freshWindow.filter { item in
            guard let sc = item.shortcode else { return false }
            return !knownShortcodes.contains(sc)
        }

        // ── Deleted shortcodes ─────────────────────────────────────────────
        //
        // ## Deletion-detection semantics
        //
        // We can only reliably detect deletions when we have enumerated all items
        // in a contiguous, bounded window and a known shortcode is absent from it.
        //
        // **Case A: cursor == nil (first / full run)**
        // The entire listing is our fresh window. Any known shortcode NOT appearing
        // in that listing is a deletion candidate (the profile no longer has it).
        //
        // **Case B: cursor was found (incremental run)**
        // The fresh window only covers items *above* the cursor — items that are
        // *newer* than the cursor. We do not know which `knownShortcodes` fall
        // above vs. below the cursor without timestamps on all known items (we only
        // have them for items currently in the listing). Flagging all known codes
        // not in the fresh window would produce massive false positives (all old
        // known codes below the cursor would be flagged). Therefore, we limit
        // deletion detection to codes that actually appeared in the *full* listing
        // (i.e., both above and below the cursor) but are absent — using the
        // all-items set as the truth source.
        //
        // **Case C: cursor was NOT found (cursor post deleted)**
        // We cannot bound the window reliably; suppress deletion detection.
        //
        // In all cases, deletions are sorted for deterministic output.
        var deletedShortcodes: [String] = []

        if cursor == nil {
            // Case A: full listing — any known code absent from listing is deleted.
            let allListingCodes = Set(allItems.compactMap { $0.shortcode })
            for sc in knownShortcodes {
                if !allListingCodes.contains(sc) {
                    deletedShortcodes.append(sc)
                }
            }
            deletedShortcodes.sort()

        } else if cursorWasFound {
            // Case B: incremental — detect deletions only among items visible in
            // the fresh window (above-cursor portion of the listing). A known
            // shortcode is a deletion candidate only if it was in the listing
            // section we scanned (freshWindow) but is absent from it.
            //
            // Since freshWindow already IS the above-cursor section, a code in
            // `knownShortcodes` that is absent from `freshWindowShortcodes` AND
            // absent from the below-cursor section (allItems minus freshWindow)
            // indicates the item was in the range we just scanned but has vanished.
            //
            // We use the simplest safe heuristic: the `freshWindowShortcodes` set
            // represents ALL codes we expect to be new or already-known in that
            // range. A known code NOT in freshWindowShortcodes is NOT detectable as
            // deleted here without knowing its original position. To avoid false
            // positives we do NOT flag codes below the cursor.
            //
            // Practical consequence: deletion detection in incremental mode is
            // limited. Use a full-profile audit command to catch deletions in older
            // content. (See "window semantics" doc in this file's header.)
            //
            // We leave this empty for the incremental cursor-found case.
            _ = freshWindowShortcodes  // no-op: deletedShortcodes stays empty

        }
        // Case C (cursor not found): deletedShortcodes stays empty.

        return EnumerationResult(
            newItems: newItems,
            deletedShortcodes: deletedShortcodes,
            newCursor: newestShortcode
        )
    }
}

// MARK: - Cursor persistence helper

extension InstagramEnumerator {

    /// Writes the enumeration cursor for `showSlug` to the `StateStore`.
    ///
    /// This is a thin helper — the algorithm itself is pure and does not call this.
    /// The pipeline layer calls this after processing `EnumerationResult`.
    ///
    /// - Parameters:
    ///   - showSlug: The show slug (primary key in `instagram_enumeration_cursor`).
    ///   - shortcode: The new cursor shortcode (last-seen newest item).
    ///   - store: The `StateStore` to write to.
    public static func persistCursor(
        showSlug: String,
        shortcode: String,
        store: StateStore
    ) throws {
        let nowISO = Event.nowISO()
        try store.upsertInstagramCursor(
            showSlug: showSlug,
            lastShortcodeSeen: shortcode,
            lastEnumerationAt: nowISO
        )
    }
}
