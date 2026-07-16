import Foundation

// MARK: - WatchlistStore

/// Mutable source of truth for the user's subscriptions.
///
/// Wraps ``Watchlist`` with add/remove/save semantics. All writes go through
/// ``save(to:)`` which uses an atomic rename so a crash cannot corrupt
/// `watchlist.yaml`.
///
/// Identity rule: two shows are considered the same when their ``Show/slug``
/// matches. ``add(_:)`` derives the slug from the show's title if the caller
/// does not supply one, and ``addPodcast(feedURL:title:author:artworkURL:)``
/// always derives the slug from the title. The `rss` field is used as a
/// secondary match in ``add(_:)`` — if an existing show has the same `rss` URL
/// but a different slug the show is updated in place (title / artworkUrl
/// refreshed) rather than duplicated.
public final class WatchlistStore {

    // MARK: - State

    /// The current in-memory watchlist.  Mutations are not persisted until
    /// ``save(to:)`` is called.
    public private(set) var watchlist: Watchlist

    /// Replays every logical edit `add`/`remove`/an `updateX` mutator has
    /// applied to `watchlist` SINCE THE LAST SAVE, against the FRESHEST
    /// on-disk copy at save time (M9 — serial writer). `nil` means "no
    /// pending edit" (a store that was only ever read, e.g. `WatchlistStore.load`
    /// used purely to inspect `watchlist.shows` — ``save(to:)`` is then a no-op).
    ///
    /// Each mutator COMPOSES onto any existing pending edit (never simply
    /// overwrites it) — a caller is free to call `add`/`remove` multiple
    /// times before a single terminal `save(to:)` (several production and
    /// test call sites do exactly this), and every one of those edits must
    /// still land, not just the last one.
    private var pendingEdit: ((inout Watchlist) -> Void)?

    /// Appends `edit` onto ``pendingEdit``, preserving the ORDER edits were
    /// made in (each closure runs in sequence against the same in-progress
    /// `Watchlist` value at save time).
    private func appendPendingEdit(_ edit: @escaping (inout Watchlist) -> Void) {
        if let existing = pendingEdit {
            pendingEdit = { wl in existing(&wl); edit(&wl) }
        } else {
            pendingEdit = edit
        }
    }

    // MARK: - Init

    /// Create a store pre-populated with `watchlist`.
    public init(watchlist: Watchlist = Watchlist()) {
        self.watchlist = watchlist
    }

    // MARK: - Load

    /// Load from a YAML file at `url`, returning an empty watchlist when the
    /// file does not exist.
    ///
    /// Coordinated (``WatchlistFileCoordinator/read(url:)``) so a load can
    /// never observe a half-written file mid-rename from a concurrent
    /// (possibly cross-process) writer.
    ///
    /// - Throws: on malformed YAML or field-type mismatches.
    public static func load(from url: URL) throws -> WatchlistStore {
        let wl = try WatchlistFileCoordinator.read(url: url)
        return WatchlistStore(watchlist: wl)
    }

    // MARK: - Mutations

    /// Append `show` if no existing show shares its slug **or** its `rss` URL.
    ///
    /// If a matching show is found (by slug first, then by `rss` as a
    /// fallback), the existing entry is updated in place with the new show's
    /// values so callers can refresh metadata without creating duplicates.
    ///
    /// - Returns: `true` when the show was newly appended, `false` when an
    ///   existing entry was updated.
    @discardableResult
    public func add(_ show: Show) -> Bool {
        let wasNew = Self.applyAdd(show, to: &watchlist)
        appendPendingEdit { wl in _ = Self.applyAdd(show, to: &wl) }
        return wasNew
    }

    /// Shared add logic — applied both to the caller-visible `watchlist` (for
    /// callers that inspect `store.watchlist` before saving) and, at save
    /// time, to the freshest on-disk copy via `pendingEdit`.
    @discardableResult
    private static func applyAdd(_ show: Show, to watchlist: inout Watchlist) -> Bool {
        // Primary key: slug
        if let idx = watchlist.shows.firstIndex(where: { $0.slug == show.slug }) {
            var updated = show
            updated.addedAt = watchlist.shows[idx].addedAt   // preserve original subscription date
            watchlist.shows[idx] = updated
            return false
        }
        // Fallback dedup: same RSS feed URL (non-empty) avoids ghost entries when
        // the caller derives a different slug from an identical feed.
        if !show.rss.isEmpty,
           let idx = watchlist.shows.firstIndex(where: { !$0.rss.isEmpty && $0.rss == show.rss }) {
            var updated = show
            updated.addedAt = watchlist.shows[idx].addedAt   // preserve original subscription date
            watchlist.shows[idx] = updated
            return false
        }
        // Genuinely new show → stamp the subscription date (unless the caller
        // already set a real one). Pre-existing shows keep the sentinel and never
        // read as "New".
        var newShow = show
        if newShow.addedAt == Show.defaultAddedAt {
            newShow.addedAt = LocalIngestService.isoDate(from: Date())
        }
        watchlist.shows.append(newShow)
        return true
    }

    /// Remove the show whose ``Show/slug`` equals `slug`.
    ///
    /// No-ops silently if no such show exists.
    public func remove(slug: String) {
        watchlist.shows.removeAll { $0.slug == slug }
        appendPendingEdit { wl in wl.shows.removeAll { $0.slug == slug } }
    }

    // MARK: - Persist

    /// Persists to `url` as ONE coordinated transaction (M9 — serial writer),
    /// routed through ``WatchlistFileCoordinator`` — the single serial write
    /// path every mutation (in-process AND the separate `vocateca-cli`
    /// process) funnels through.
    ///
    /// Two shapes, depending on how this store came to hold its current state:
    ///
    /// 1. **A pending edit exists** (`add`/`remove`/an `updateX` mutator ran
    ///    since the last save): rather than blindly serialising `self.watchlist`
    ///    (a snapshot that may already be stale by the time this runs), this
    ///    re-reads the FRESHEST on-disk copy and re-applies the SAME logical
    ///    edit(s) the caller made — closing the read-modify-write race even
    ///    when another writer touched the file in between.
    ///
    /// 2. **No pending edit** — a store built via ``init(watchlist:)`` (a
    ///    direct, whole-value construction: `WatchlistStore(watchlist: someWatchlist)`)
    ///    and saved with no mutator call at all. This is a legitimate,
    ///    pre-existing pattern (production `OPMLImporter`, and several test
    ///    fixtures that seed a specific watchlist state directly) — it must
    ///    persist `self.watchlist` VERBATIM, an explicit whole-value
    ///    overwrite, not a merge. Still routed through the SAME coordinator
    ///    for atomicity and cross-process serialisation.
    ///
    /// `self.watchlist` is refreshed to the just-written on-disk state
    /// afterwards (case 1 only — case 2 already IS that state), so a caller
    /// that keeps using `store.watchlist` post-save (some UI call sites do,
    /// to update in-memory display state) sees the real persisted result
    /// rather than its possibly-superseded local copy.
    ///
    /// - Throws: ``Watchlist/saveAtomic(to:)`` errors (YAML encoding failure or
    ///   filesystem errors), or coordination errors.
    public func save(to url: URL) throws {
        guard let pendingEdit else {
            // Case 2: no mutator ran — persist the whole in-memory value as an
            // explicit overwrite (the historical, pre-M9 `save` contract).
            try WatchlistFileCoordinator.perform(url: url) { _ in (write: watchlist, result: ()) }
            return
        }
        // Case 1: replay the accumulated edit(s) against the freshest on-disk copy.
        let saved = try WatchlistFileCoordinator.perform(url: url) { onDisk in
            var mutated = onDisk
            pendingEdit(&mutated)
            return (write: mutated, result: mutated)
        }
        watchlist = saved
        self.pendingEdit = nil
    }

    /// Applies `edit` to the in-memory `watchlist` (so an immediate
    /// `store.watchlist` read reflects the change) AND stages the identical
    /// closure as the pending edit for ``save(to:)`` to re-apply against the
    /// freshest on-disk copy (M9 — serial writer).
    ///
    /// Every single-field `updateX` mutator below is a thin wrapper around
    /// this: the by-slug field mutation is expressed once as `edit` and
    /// replayed twice — immediately (in memory) and again, from fresh disk
    /// state, inside the coordinated transaction — so both the caller's
    /// in-memory view and the persisted result are correct even if another
    /// writer (in-process or `vocateca-cli`) touched the file in between.
    private func mutateAndSave(to url: URL, _ edit: @escaping (inout Watchlist) -> Void) throws {
        edit(&watchlist)
        appendPendingEdit(edit)
        try save(to: url)
    }

    // MARK: - Convenience

    /// Construct a ``Show`` from podcast metadata and persist it.
    ///
    /// The slug is derived from `title` by lower-casing, replacing runs of
    /// non-alphanumeric characters with a single hyphen, and trimming trailing
    /// hyphens. The `rss` field is set to `feedURL`, `source` to `"podcast"`,
    /// and `artworkUrl` to `artworkURL` (defaulting to `""`).
    ///
    /// If a show with the same slug or `rss` already exists it is updated in
    /// place (see ``add(_:)``).
    ///
    /// - Parameters:
    ///   - feedURL:    The RSS feed URL string.
    ///   - title:      Human-readable podcast title (used to derive the slug).
    ///   - author:     Podcast author / artist name (stored in ``Show/author``).
    ///   - artworkURL: Optional artwork URL string.
    ///   - backfillMode:  Chosen import-scope mode (``BackfillMode``); defaults to `.all`.
    ///   - backfillN:     "Last N" count, stored regardless of mode; defaults to 10.
    ///   - backfillSince: ISO since-date, stored regardless of mode; defaults to `""`.
    ///   - to:         File URL to persist the updated watchlist to.
    ///
    /// - Throws: when ``save(to:)`` fails.
    public func addPodcast(
        feedURL: String,
        title: String,
        author: String,
        artworkURL: String? = nil,
        language: String = Show.defaultLanguage,
        backfillMode: BackfillMode = .all,
        backfillN: Int = 10,
        backfillSince: String = "",
        to url: URL
    ) throws {
        let slug = Self.slugify(title)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        // Store only the primary subtag: the ASR engines take "de", not "de-DE",
        // and a feed's `<language>` routinely carries a region suffix.
        let normalizedLanguage = Show.isAutoLanguage(language)
            ? Show.defaultLanguage
            : Show.primaryLanguageSubtag(language)
        let show = Show(
            slug: slug,
            title: title,
            rss: feedURL,
            language: normalizedLanguage,
            artworkUrl: artworkURL ?? Show.defaultArtworkUrl,
            source: "podcast",
            backfillMode: backfillMode.rawValue,
            backfillN: backfillN,
            backfillSince: backfillSince,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor
        )
        Log.info("Podcast added", component: "Watchlist",
                 context: [("slug", slug), ("language", normalizedLanguage.isEmpty ? "auto" : normalizedLanguage)])
        add(show)
        try save(to: url)
    }

    /// Updates the `author` field of the show identified by `slug` in memory
    /// and persists the change atomically to `url`.
    ///
    /// Used during feed refresh to backfill the author from `<itunes:author>`.
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:   The show to update.
    ///   - author: The author string, or nil/empty to clear.
    ///   - url:    The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateAuthor(slug: String, author: String?, to url: URL) throws {
        let trimmed = author?.trimmingCharacters(in: .whitespaces) ?? ""
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].author = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Updates the `language` field of the show identified by `slug` in memory
    /// and persists the change atomically to `url`.
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:     The show to update.
    ///   - language: The new language code (e.g. `"en"`, `"de"`, `""`).
    ///   - url:      The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateLanguage(slug: String, language: String, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].language = language
        }
    }

    /// Updates the `whisperPrompt` field of the show identified by `slug` in
    /// memory and persists the change atomically to `url`.
    ///
    /// The prompt biases the transcription model toward specific spellings,
    /// names, or jargon. No-ops (does not throw) when no show matches.
    ///
    /// - Parameters:
    ///   - slug:   The show to update.
    ///   - prompt: The new Whisper prompt (may be empty to clear).
    ///   - url:    The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateWhisperPrompt(slug: String, prompt: String, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].whisperPrompt = prompt
        }
    }

    /// Updates the `minDurationSec`/`maxDurationSec` fields of the show
    /// identified by `slug` in memory and persists the change atomically to `url`.
    ///
    /// Episodes shorter than `minSec` or longer than `maxSec` are skipped by
    /// the pipeline before download. `0` means "no limit" for either bound.
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:   The show to update.
    ///   - minSec: Minimum episode duration in seconds, or `0` for no limit.
    ///   - maxSec: Maximum episode duration in seconds, or `0` for no limit.
    ///   - url:    The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateDurationLimits(slug: String, minSec: Int, maxSec: Int, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].minDurationSec = minSec
            wl.shows[idx].maxDurationSec = maxSec
        }
    }

    /// Updates the per-show music-detection opt-out (`assumeSpeech`) of the show
    /// identified by `slug` in memory and persists the change atomically to `url`.
    ///
    /// `true` = "Always spoken word" (never skip an episode as music);
    /// `false` = "Auto-detect (skip music)" (the no-speech detector may skip).
    ///
    /// No-ops when no show with the given slug is found.
    public func updateAssumeSpeech(slug: String, assumeSpeech: Bool, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].assumeSpeech = assumeSpeech
        }
    }

    /// Updates the `enabled` field of the show identified by `slug` in memory
    /// and persists the change atomically to `url`.
    ///
    /// No-ops when no show with the given slug is found.
    public func updateEnabled(slug: String, enabled: Bool, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].enabled = enabled
        }
    }

    /// Updates the `creator` field of the show identified by `slug` in memory
    /// and persists the change atomically to `url`.
    ///
    /// Passing a nil or whitespace-only string clears the creator assignment so
    /// the aggregator falls back to title-root heuristics.
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:    The show to update.
    ///   - creator: The new creator name, or nil/empty to clear the assignment.
    ///   - url:     The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateCreator(slug: String, creator: String?, to url: URL) throws {
        let trimmed = creator?.trimmingCharacters(in: .whitespaces) ?? ""
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].creator = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Assigns the same explicit `creator` to every show in `slugs` in a SINGLE
    /// atomic write — used by the Library's drag-and-drop creator merge, which
    /// reassigns a whole creator group's shows to another creator at once.
    /// Unknown slugs are skipped. Passing nil/empty clears the assignment.
    public func updateCreators(slugs: [String], creator: String?, to url: URL) throws {
        let trimmed = creator?.trimmingCharacters(in: .whitespaces) ?? ""
        let slugSet = Set(slugs)
        try mutateAndSave(to: url) { wl in
            for idx in wl.shows.indices where slugSet.contains(wl.shows[idx].slug) {
                wl.shows[idx].creator = trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    /// Groups the shows in `slugs` under one `creator` AND propagates a fallback
    /// thumbnail, in a SINGLE atomic write — the Library's drag-a-show-onto-
    /// another merge.
    ///
    /// `artworkFallback` (the first non-empty artwork among the merged shows) is
    /// written ONLY into shows whose own `artworkUrl` is empty, so a
    /// thumbnail-less source adopts the available one while shows that already
    /// have their own thumbnail keep it untouched. Empty `artworkFallback` (no
    /// source had artwork) leaves every artwork as-is. Unknown slugs are skipped.
    public func mergeShows(slugs: [String], creator: String, artworkFallback: String, to url: URL) throws {
        let trimmedCreator = creator.trimmingCharacters(in: .whitespaces)
        let fallback = artworkFallback.trimmingCharacters(in: .whitespaces)
        let slugSet = Set(slugs)
        try mutateAndSave(to: url) { wl in
            for idx in wl.shows.indices where slugSet.contains(wl.shows[idx].slug) {
                wl.shows[idx].creator = trimmedCreator.isEmpty ? nil : trimmedCreator
                if !fallback.isEmpty, wl.shows[idx].artworkUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                    wl.shows[idx].artworkUrl = fallback
                }
            }
        }
    }

    /// Updates the user-overridable display-name override (``Show/customTitle``)
    /// of the show identified by `slug` in memory and persists the change
    /// atomically to `url`.
    ///
    /// Passing a nil or whitespace-only string CLEARS the override, so the
    /// show reverts to its feed ``Show/title`` (see ``Show/displayName``).
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:        The show to update.
    ///   - customTitle: The new display-name override, or nil/empty to clear it.
    ///   - url:         The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateTitle(slug: String, customTitle: String?, to url: URL) throws {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].customTitle = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Updates the unified backfill policy (``BackfillMode`` + N + since-date)
    /// of the show identified by `slug` in memory and persists the change
    /// atomically to `url`.
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:  The show to update.
    ///   - mode:  The new import-scope mode.
    ///   - n:     "Last N" item count, stored regardless of `mode` (only
    ///     meaningful when `mode == .lastN`).
    ///   - since: ISO `YYYY-MM-DD` since-date, stored regardless of `mode`
    ///     (only meaningful when `mode == .sinceDate`).
    ///   - url:   The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateBackfill(slug: String, mode: BackfillMode, n: Int, since: String, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].backfillMode = mode.rawValue
            wl.shows[idx].backfillN = n
            wl.shows[idx].backfillSince = since
        }
    }

    /// Updates the per-show media-retention override (``Show/mediaRetentionOverrideDays``)
    /// of the show identified by `slug` in memory and persists the change
    /// atomically to `url`.
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug: The show to update.
    ///   - days: The new override (`-1` = follow global, `0` = keep forever,
    ///     `N > 0` = delete media after N days).
    ///   - url:  The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateMediaRetentionOverride(slug: String, days: Int, to url: URL) throws {
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }
            wl.shows[idx].mediaRetentionOverrideDays = days
        }
    }

    /// Apply refreshed metadata from ``MetadataRefresher`` to the show identified
    /// by `slug`, overwriting only fields whose incoming value is non-nil AND
    /// non-empty (never blanks out existing good data with an empty origin value).
    ///
    /// For YouTube and Instagram sources: if `metadata.handle` is present and the
    /// show has no existing `author`, the handle is used as the author (mirrors
    /// the FeedIngestor behaviour where @handle is the author).
    ///
    /// No-ops (does not throw) when no show with the given slug is found.
    ///
    /// - Parameters:
    ///   - slug:     The show to update.
    ///   - metadata: The refreshed metadata (from ``MetadataRefresher.fetch``).
    ///   - url:      The watchlist YAML file to persist to.
    /// - Throws: When the atomic write fails.
    public func updateMetadata(slug: String, metadata: RefreshedMetadata, to url: URL) throws {
        // Helper: apply a value only when incoming is non-nil and non-empty.
        func applyIfPresent(_ incoming: String?, into field: inout String) {
            guard let v = incoming, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            field = v.trimmingCharacters(in: .whitespaces)
        }

        // M9: the author-vs-handle fallback below reads the CURRENT author to
        // decide whether to apply the handle — this must be the freshest
        // on-disk value (not a possibly-stale in-memory one), since this is
        // one of the two named concurrent writers (IngestCoordinator's
        // metadata-refresh races FeedIngestor's own author-backfill via
        // updateAuthor). mutateAndSave's `wl` argument is re-read from disk
        // on every save, so this closure always decides from fresh state.
        try mutateAndSave(to: url) { wl in
            guard let idx = wl.shows.firstIndex(where: { $0.slug == slug }) else { return }

            applyIfPresent(metadata.title,      into: &wl.shows[idx].title)
            applyIfPresent(metadata.artworkURL, into: &wl.shows[idx].artworkUrl)

            // Author: prefer explicit author; fall back to handle when author is absent.
            if let author = metadata.author, !author.trimmingCharacters(in: .whitespaces).isEmpty {
                wl.shows[idx].author = author.trimmingCharacters(in: .whitespaces)
            } else if let handle = metadata.handle,
                      !handle.trimmingCharacters(in: .whitespaces).isEmpty,
                      (wl.shows[idx].author ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                // Use handle as author only when the existing (fresh) author is also absent.
                wl.shows[idx].author = handle.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// Construct a ``Show`` for an Instagram profile and persist it.
    ///
    /// The handle is normalised (leading `@` stripped, lowercased) before use.
    /// The slug is derived via ``slugify(_:)`` from the bare handle. `rss` is
    /// always `""` (Instagram has no RSS feed). `artworkUrl` is always `""`
    /// (no live avatar fetch — that is deferred to WP-5). Dedup is handled
    /// by ``add(_:)`` (slug-based), so calling this twice with the same handle
    /// updates the existing entry in place rather than appending a duplicate.
    ///
    /// - Parameters:
    ///   - handle:      The Instagram handle, with or without a leading `@`.
    ///   - reels:       Whether to monitor Reels content.
    ///   - posts:       Whether to monitor Posts content.
    ///   - stories:     Whether to monitor Stories content.
    ///   - backfillMode: The legacy IG backfill strategy raw value (`"forward"`, `"last_n"`, `"full"`).
    ///   - backfillN:   Number of posts for the `last_n` legacy backfill mode.
    ///   - unifiedBackfillMode: The unified import-scope mode (``BackfillMode``); defaults to `.all`.
    ///   - unifiedBackfillN:   "Last N" count for the unified policy, stored regardless of mode; defaults to 10.
    ///   - unifiedBackfillSince: ISO since-date for the unified policy; defaults to `""`.
    ///   - to:          File URL to persist the updated watchlist to.
    ///
    /// - Returns: The ``Show`` that was appended or updated.
    /// - Throws: when ``save(to:)`` fails.
    @discardableResult
    public func addInstagram(
        handle: String,
        reels: Bool,
        posts: Bool,
        stories: Bool,
        backfillMode: String,
        backfillN: Int,
        unifiedBackfillMode: BackfillMode = .all,
        unifiedBackfillN: Int = 10,
        unifiedBackfillSince: String = "",
        to url: URL
    ) throws -> Show {
        // Normalise: strip leading @, lowercase.
        let raw = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let normalised = raw.lowercased()
        let displayHandle = "@\(normalised)"

        Log.debug("addInstagram: normalised handle",
                  component: "WatchlistStore",
                  context: [("raw", handle), ("normalised", normalised)])

        let slug = Self.slugify(normalised)
        let show = Show(
            slug: slug,
            title: displayHandle,
            rss: "",           // Instagram has no RSS feed
            artworkUrl: "",    // No live avatar fetch — deferred to WP-5
            source: "instagram",
            igReels: reels,
            igPosts: posts,
            igStories: stories,
            igBackfillMode: backfillMode,
            igBackfillN: backfillN,
            backfillMode: unifiedBackfillMode.rawValue,
            backfillN: unifiedBackfillN,
            backfillSince: unifiedBackfillSince,
            author: displayHandle
        )

        add(show)
        try save(to: url)

        Log.info("addInstagram: show added/updated",
                 component: "WatchlistStore",
                 context: [("slug", slug), ("handle", displayHandle),
                            ("reels", "\(reels)"), ("posts", "\(posts)"),
                            ("stories", "\(stories)"), ("backfillMode", backfillMode),
                            ("backfillN", "\(backfillN)")])

        return show
    }

    /// Subscribes to a YouTube channel. Stores a `source="youtube"` show whose
    /// `rss` is the channel RSS feed (`feeds/videos.xml?channel_id=…`), which
    /// `FeedIngestor` resolves on the next poll. `skipShorts`/`language` carry the
    /// per-subscription content preferences.
    ///
    /// - Parameters:
    ///   - backfillMode:  Chosen import-scope mode (``BackfillMode``); defaults to `.all`.
    ///   - backfillN:     "Last N" count, stored regardless of mode; defaults to 10.
    ///   - backfillSince: ISO since-date, stored regardless of mode; defaults to `""`.
    public func addYouTube(
        channelID: String,
        title: String,
        author: String,
        skipShorts: Bool,
        includeVideos: Bool = true,
        language: String,
        backfillMode: BackfillMode = .all,
        backfillN: Int = 10,
        backfillSince: String = "",
        to url: URL
    ) throws {
        let slug = Self.slugify(title)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        var show = Show(
            slug: slug,
            title: title,
            rss: YouTubeURL.rssURL(forChannelID: channelID),
            artworkUrl: Show.defaultArtworkUrl,
            source: "youtube",
            backfillMode: backfillMode.rawValue,
            backfillN: backfillN,
            backfillSince: backfillSince,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor
        )
        show.skipShorts = skipShorts
        show.includeVideos = includeVideos
        if language != "Auto" { show.language = language }
        add(show)
        try save(to: url)
    }

    /// Construct a ``Show`` for a generic yt-dlp playlist/channel and persist it.
    ///
    /// The slug is derived from `title` via ``slugify(_:)``. The `rss` field is
    /// set to `channelURL` (the yt-dlp enumerate target), `source` to `"ytdlp"`,
    /// and `artworkUrl` to `""` (no live artwork fetch at subscribe time).
    ///
    /// Dedup is handled by ``add(_:)`` — calling this twice with the same URL
    /// updates the existing entry in place.
    ///
    /// - Parameters:
    ///   - channelURL: The playlist or channel URL that yt-dlp can enumerate.
    ///   - title:      Human-readable title (from ``MediaURLResolver`` metadata).
    ///   - author:     Uploader/channel name from yt-dlp metadata.
    ///   - to:         File URL to persist the updated watchlist to.
    ///
    /// - Returns: The ``Show`` that was appended or updated.
    /// - Throws: when ``save(to:)`` fails.
    @discardableResult
    public func addYtDlp(
        channelURL: String,
        title:      String,
        author:     String,
        to url:     URL
    ) throws -> Show {
        let slug = Self.slugify(title)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)

        Log.debug("addYtDlp: adding show",
                  component: "WatchlistStore",
                  context: [("slug", slug), ("url", channelURL)])

        let show = Show(
            slug:   slug,
            title:  title,
            rss:    channelURL,
            source: "ytdlp",
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor
        )

        add(show)
        try save(to: url)

        Log.info("addYtDlp: show added/updated",
                 component: "WatchlistStore",
                 context: [("slug", slug), ("author", trimmedAuthor)])

        return show
    }

    /// Reconnects an **orphaned DB-only show** (episodes exist in `state.sqlite`
    /// under `slug`, but the watchlist entry was lost) to a live feed, using the
    /// slug **verbatim** — never re-derived via ``slugify(_:)``. That is the whole
    /// point: the existing DB episodes are keyed to this exact slug, so writing
    /// the watchlist entry back under the same slug re-attaches the feed and
    /// metadata without touching a single episode row. Future polls resolve
    /// `showSlug: slug` in ``StateStore/upsertEpisodeFromFeed`` and, thanks to its
    /// `INSERT OR IGNORE` semantics, existing `guid`s (and their `status` /
    /// `transcript_path`) are preserved — only new episodes are added.
    ///
    /// If a watchlist entry already exists for `slug` (shouldn't happen for a
    /// true orphan, but guarded), its rss/title/author/artwork are updated in
    /// place rather than appending a duplicate (mirrors ``add(_:)``).
    ///
    /// - Parameters:
    ///   - slug:       The EXACT existing DB show slug to bind to (verbatim).
    ///   - rss:        The feed URL the user supplied.
    ///   - title:      The channel title parsed from the feed (fallback: `slug`
    ///                 when empty, so the show never displays a blank name).
    ///   - author:     Optional author/publisher parsed from the feed.
    ///   - artworkURL: Optional artwork URL parsed from the feed.
    ///   - url:        The watchlist YAML file to persist to.
    /// - Throws: When ``save(to:)`` fails.
    public func reconnectShow(
        slug: String,
        rss: String,
        title: String,
        author: String? = nil,
        artworkURL: String? = nil,
        to url: URL
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAuthor = author?.trimmingCharacters(in: .whitespaces) ?? ""
        let show = Show(
            slug: slug,                                   // verbatim — NOT slugify(title)
            title: trimmedTitle.isEmpty ? slug : trimmedTitle,
            rss: rss,
            artworkUrl: artworkURL ?? Show.defaultArtworkUrl,
            source: "podcast",
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor
        )
        add(show)
        try save(to: url)

        Log.info("WatchlistStore.reconnectShow: orphaned show reconnected",
                  component: "WatchlistStore",
                  context: [("slug", slug), ("rss", rss),
                             ("title", show.title)])
    }

    // MARK: - Internal helpers

    /// Convert a human-readable title to a URL-safe slug.
    ///
    /// Rules (matching the Python v1 `slugify` helper):
    /// 1. Lowercase the string.
    /// 2. Replace any run of characters that are not ASCII letters or digits
    ///    with a single hyphen.
    /// 3. Strip leading and trailing hyphens.
    /// 4. If the result is empty (e.g. the title contained only symbols), fall
    ///    back to `"show"`.
    public static func slugify(_ title: String) -> String {
        let lower = title.lowercased()
        // Fold non-alphanumeric runs to a single "-"
        var result = ""
        var lastWasHyphen = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                // Restrict to ASCII-range for predictability; non-ASCII letters
                // are passed through as-is (they are valid in YAML keys).
                result.append(ch)
                lastWasHyphen = false
            } else {
                if !lastWasHyphen && !result.isEmpty {
                    result.append("-")
                    lastWasHyphen = true
                }
            }
        }
        // Trim trailing hyphen
        while result.last == "-" { result.removeLast() }
        return result.isEmpty ? "show" : result
    }
}
