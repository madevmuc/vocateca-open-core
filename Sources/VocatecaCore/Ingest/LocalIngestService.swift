import Foundation

// MARK: - IngestResult

/// Describes the outcome of registering a single file or URL into the pipeline.
public struct IngestResult: Sendable, Equatable {
    /// The source file URL (for files) or the resolved webpage URL (for URLs).
    public let fileURL: URL
    /// The episode GUID assigned: `"local:<fnv1a-hex>"`.
    public let guid: String
    /// The show slug the episode was registered under.
    public let showSlug: String
    /// `true` when the row was freshly inserted; `false` on a duplicate (no-op).
    public let isNew: Bool

    public init(fileURL: URL, guid: String, showSlug: String, isNew: Bool) {
        self.fileURL  = fileURL
        self.guid     = guid
        self.showSlug = showSlug
        self.isNew    = isNew
    }
}

// MARK: - LocalIngestService

/// Core service for registering local files and one-off URL items into the
/// Vocateca pipeline.
///
/// This service extracts the register-file logic that previously lived inside
/// `AutomationRunner.handleNewWatchedFile` (VocatecaPro) into the open Core
/// module so that **Free** manual-import paths (drag-drop, Choose Files…,
/// Choose Folder…) can share the same implementation without a Pro entitlement.
///
/// ## Grouping rules
/// - `importFolder(_:)` — the folder's name becomes the show slug.
/// - `import(fileURLs:)` — loose files land in the "Local files" bucket show.
/// - `importURL(...)` — one-off URL import, caller supplies slug/title.
///
/// ## Pseudo-show registration
/// Before upserting episodes the service ensures a minimal `source="local"` Show
/// entry exists in the watchlist YAML. These pseudo-shows are never polled by
/// `FeedIngestor` (guarded alongside `"instagram"` and `"local"`).
///
/// ## Dedup
/// The GUID is `"local:<fnv1a-hex>"` of the file's absolute path (for files) or
/// the resolved webpage URL (for URL imports). Re-importing the same path is a
/// no-op — the ON CONFLICT path in `upsertEpisodeFromFeed` preserves pipeline
/// state and simply refreshes metadata.
///
/// ## Caller responsibility
/// Draining the queue after registration is the caller's responsibility. The
/// service registers episodes as `pending` but does NOT start the `QueueRunner`.
public struct LocalIngestService: Sendable {

    // MARK: - Constants

    /// The fixed slug for the "Local files" bucket show (loose drops / Choose Files…).
    public static let localFilesBucketSlug  = "local-files"
    /// The human-readable title for the bucket show.
    public static let localFilesBucketTitle = "Local files"

    /// True when `guid` is a one-off/local import (GUID format `local:<hash>`).
    /// Used to decide whether a finished transcription should auto-open the Library.
    public static func isOneOffGuid(_ guid: String) -> Bool {
        guid.hasPrefix("local:")
    }

    // MARK: - Dependencies

    private let store: StateStore
    private let watchlistURL: URL?

    // MARK: - Init

    /// Creates a service backed by `store`.
    ///
    /// - Parameters:
    ///   - store: The state store to upsert episodes into.
    ///   - watchlistURL: URL for the watchlist YAML file. Pass `Paths.watchlistURL`
    ///     in production; pass `nil` in tests that do not need watchlist writes.
    public init(store: StateStore, watchlistURL: URL? = nil) {
        self.store        = store
        self.watchlistURL = watchlistURL
    }

    // MARK: - import(fileURLs:) — loose files → "Local files" bucket

    /// Registers each ingestable file in `fileURLs` under the "Local files"
    /// bucket show (`slug = "local-files"`).
    ///
    /// Non-ingestable extensions are silently skipped. A failing individual file
    /// is logged and skipped so the rest of the batch proceeds.
    ///
    /// - Returns: One ``IngestResult`` per *ingestable* file URL in `fileURLs`.
    public func `import`(fileURLs: [URL]) throws -> [IngestResult] {
        let slug  = Self.localFilesBucketSlug
        let title = Self.localFilesBucketTitle
        try ensureLocalShow(slug: slug, title: title)
        return ingestFiles(fileURLs, into: slug)
    }

    // MARK: - importFolder(_:) — folder name → show slug

    /// Recursively registers all ingestable files under `url` into a show
    /// whose slug is derived from the folder's last path component name.
    ///
    /// If `url` is not a directory it is treated as a loose file and lands in
    /// the "Local files" bucket (same as `import(fileURLs:)`).
    ///
    /// - Parameter url: A directory URL to scan.
    /// - Returns: One ``IngestResult`` per ingestable file found under `url`.
    public func importFolder(_ url: URL) throws -> [IngestResult] {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        guard isDir.boolValue else {
            return try `import`(fileURLs: [url])
        }

        let folderName = url.lastPathComponent
        let slug       = Self.slugForFolderName(folderName)
        let title      = folderName.isEmpty ? Self.localFilesBucketTitle : folderName
        try ensureLocalShow(slug: slug, title: title)

        let files = FolderScan.newMediaFiles(in: url, knownPaths: [])
        return ingestFiles(files, into: slug)
    }

    // MARK: - importURL — one-off URL → caller-supplied show

    /// Registers a single item resolved by ``MediaURLResolver`` as a one-off
    /// episode under a caller-supplied show slug.
    ///
    /// Used by `AddSourceSheet`'s "Import once" path. The `webpageURL` is stored
    /// as the `mp3_url` placeholder; the queue worker routes it through the yt-dlp
    /// audio hook because it is not a direct audio file extension.
    ///
    /// - Parameters:
    ///   - title:      Episode title from resolver metadata.
    ///   - webpageURL: Resolved webpage URL (dedup key + audio hook input).
    ///   - showSlug:   Target show slug (derived from uploader name by caller).
    ///   - showTitle:  Human-readable pseudo-show title.
    ///   - artworkURL: Optional thumbnail URL (from yt-dlp) for the pseudo-show.
    ///   - author:     Optional author / creator name (iTunes `artistName`,
    ///                 YouTube channel, etc.). When non-empty it is stored as the
    ///                 pseudo-show's `author` and `creator` so the one-off appears
    ///                 under a real creator in the Creators tab rather than a slug.
    ///   - source:     The real content source for classification (N4): "youtube",
    ///                 "instagram", "podcast", or "other". The caller (OneOffSheet)
    ///                 knows the detected link kind and threads it in so a YouTube
    ///                 one-off classifies under the YouTube tab. Defaults to
    ///                 "local" for file/folder imports.
    /// - Returns: ``IngestResult`` for the registered item.
    public func importURL(
        title:      String,
        webpageURL: String,
        showSlug:   String,
        showTitle:  String,
        artworkURL: String = "",
        author:     String? = nil,
        source:     String = "local"
    ) throws -> IngestResult {
        try ensureLocalShow(slug: showSlug, title: showTitle, artworkURL: artworkURL, author: author, source: source)

        let guid    = "local:\(Self.fnv1aHex(webpageURL))"
        let pubDate = Self.todayISO()
        let isNew   = (try store.upsertEpisodeFromFeed(
            showSlug:    showSlug,
            guid:        guid,
            title:       title,
            pubDate:     pubDate,
            mp3URL:      webpageURL,
            durationSec: nil
        )) != nil

        Log.debug("LocalIngestService: URL import",
                  component: "LocalIngest",
                  context: [("guid", guid), ("new", "\(isNew)"), ("show", showSlug)])

        let url = URL(string: webpageURL) ?? URL(fileURLWithPath: webpageURL)
        return IngestResult(fileURL: url, guid: guid, showSlug: showSlug, isNew: isNew)
    }

    // MARK: - Slug helpers (public — reused by AutomationRunner)

    /// Derives a show slug from a file's top-level subfolder under a watch root.
    ///
    /// Mirrors the `slugForWatch` logic in `AutomationRunner`. Loose files at
    /// the root (no subfolder) go to the `localFilesBucketSlug` catch-all.
    public static func slugForWatch(fileURL: URL, root: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return localFilesBucketSlug }
        let relative = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return localFilesBucketSlug }
        return TextNormalization.slugify(String(parts[0]))
    }

    /// Derives a show slug from a folder name via `TextNormalization.slugify`.
    public static func slugForFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return localFilesBucketSlug }
        let slug = TextNormalization.slugify(trimmed)
        // TextNormalization.slugify("") returns "show" as a generic fallback;
        // if the folder name was non-empty but all symbols stripped → use bucket.
        guard slug != "show" || !trimmed.isEmpty else { return localFilesBucketSlug }
        return slug
    }

    // MARK: - FNV-1a hash

    /// Computes the FNV-1a 64-bit hash of `string` as a zero-padded 16-char hex string.
    ///
    /// `public` so tests can verify the GUID derivation formula directly, matching
    /// the existing hash in `AutomationRunner.handleNewWatchedFile`.
    public static func fnv1aHex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return UUID().uuidString }
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Private helpers

    private func ingestFiles(_ urls: [URL], into showSlug: String) -> [IngestResult] {
        var results: [IngestResult] = []
        for url in urls {
            guard FolderScan.isIngestable(url) else { continue }
            do {
                let result = try registerFile(url, showSlug: showSlug)
                results.append(result)
            } catch {
                print("[LocalIngestService] failed to register \(url.lastPathComponent): \(error)")
            }
        }
        return results
    }

    private func registerFile(_ url: URL, showSlug: String) throws -> IngestResult {
        let guid    = "local:\(Self.fnv1aHex(url.path))"
        let title   = url.deletingPathExtension().lastPathComponent
        let pubDate = fileModificationDateISO(url)

        let isNew = (try store.upsertEpisodeFromFeed(
            showSlug:    showSlug,
            guid:        guid,
            title:       title,
            pubDate:     pubDate,
            mp3URL:      url.absoluteString,
            durationSec: nil
        )) != nil

        Log.debug("LocalIngestService: registered file",
                  component: "LocalIngest",
                  context: [("guid", guid), ("new", "\(isNew)"), ("show", showSlug),
                             ("file", url.lastPathComponent)])
        return IngestResult(fileURL: url, guid: guid, showSlug: showSlug, isNew: isNew)
    }

    private func ensureLocalShow(slug: String, title: String, artworkURL: String = "", author: String? = nil, source: String = "local") throws {
        guard let wlURL = watchlistURL else { return }

        let wlStore: WatchlistStore
        do {
            wlStore = try WatchlistStore.load(from: wlURL)
        } catch {
            wlStore = WatchlistStore()
        }

        let cleanAuthor = author?.trimmingCharacters(in: .whitespaces) ?? ""

        // Already exists: backfill artwork/author if we now have them and they
        // were empty (updateMetadata only overwrites when the incoming value is
        // non-empty). Creator is backfilled separately as updateMetadata does
        // not touch it.
        if let existing = wlStore.watchlist.shows.first(where: { $0.slug == slug }) {
            if !artworkURL.isEmpty || !cleanAuthor.isEmpty {
                try? wlStore.updateMetadata(
                    slug: slug,
                    metadata: RefreshedMetadata(title: nil,
                                                author: cleanAuthor.isEmpty ? nil : cleanAuthor,
                                                artworkURL: artworkURL.isEmpty ? nil : artworkURL,
                                                handle: nil),
                    to: wlURL
                )
            }
            // Assign the creator only when the show has none yet, so a later
            // one-off never clobbers a creator the user set by hand.
            if !cleanAuthor.isEmpty,
               (existing.creator ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                try? wlStore.updateCreator(slug: slug, creator: cleanAuthor, to: wlURL)
            }
            return
        }

        // Real content source for classification (N4): a YouTube one-off must
        // land under the YouTube tab, an Instagram one-off under Instagram, a
        // resolved podcast under Podcasts, and anything else (loose files, web
        // links) under "Other". `FeedIngestor` never polls these — it is guarded
        // on the persisted `oneOff` flag / empty `rss`, not the source string.
        let cleanSource = source.trimmingCharacters(in: .whitespaces).lowercased()
        let resolvedSource = cleanSource.isEmpty ? "other" : cleanSource

        let show = Show(
            slug:       slug,
            title:      title,
            rss:        "",
            enabled:    false,   // one-off pseudo-shows are never polled
            oneOff:     true,    // persisted identity → reliable F2/feed-gate (survives a watchlist round-trip)
            artworkUrl: artworkURL,
            source:     resolvedSource,
            author:     cleanAuthor.isEmpty ? nil : cleanAuthor,
            creator:    cleanAuthor.isEmpty ? nil : cleanAuthor
        )
        wlStore.add(show)
        try wlStore.save(to: wlURL)

        Log.info("LocalIngestService: created one-off pseudo-show",
                 component: "LocalIngest",
                 context: [("slug", slug), ("title", title), ("source", resolvedSource),
                           ("author", cleanAuthor.isEmpty ? "none" : cleanAuthor),
                           ("artwork", artworkURL.isEmpty ? "none" : "yes")])
    }

    private func fileModificationDateISO(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? Date()
        return Self.isoDate(from: mtime)
    }

    /// Formats a `Date` as `YYYY-MM-DD` in UTC.
    public static func isoDate(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func todayISO() -> String { isoDate(from: Date()) }
}
