import Foundation

// MARK: - IndexedEpisode

/// An episode joined with its on-disk transcript file path (if found).
///
/// The `transcriptURL` is non-nil when a `.md` file exists under
/// `<outputRoot>/<showSlug>/` whose stem matches the episode's slug or
/// whose YAML frontmatter contains the matching `guid`.
public struct IndexedEpisode: Sendable, Equatable {
    /// The episode record from the state database.
    public let episode: Episode

    /// Absolute URL to the transcript `.md` file on disk, or `nil` when not
    /// yet transcribed or when the file has been removed.
    public let transcriptURL: URL?

    public init(episode: Episode, transcriptURL: URL?) {
        self.episode = episode
        self.transcriptURL = transcriptURL
    }
}

// MARK: - SearchResult

/// A single search result returned by ``LibrarySearch``.
public struct SearchResult: Sendable, Equatable {
    /// The indexed episode that matched.
    public let indexedEpisode: IndexedEpisode

    /// Relevance score (higher = more relevant). Always > 0 for returned results.
    public let score: Double

    public init(indexedEpisode: IndexedEpisode, score: Double) {
        self.indexedEpisode = indexedEpisode
        self.score = score
    }
}

// MARK: - LibraryIndex

/// In-memory index of the transcript library.
///
/// Joins episodes from the state database with on-disk `.md` transcript files
/// under `<outputRoot>/<showSlug>/`. Read-only; safe to call on any thread.
///
/// ## Design
/// Mirrors `core/library.py::LibraryIndex` but is Swift-native: scans the
/// output root once, builds a `slug→URL` lookup per show directory, then joins
/// against the injected episode list using `makeSlug(_:)` (same algorithm as
/// `MarkdownLibraryWriter`). Falls back to frontmatter GUID lookup for episodes
/// whose slug differs from the filename (e.g. older transcripts).
///
/// ## Testability
/// Use ``init(outputRoot:episodes:)`` directly in tests with a temp directory
/// and injected episode list — no real library or live DB required.
public struct LibraryIndex: Sendable {

    // MARK: - Properties

    /// The root directory scanned for transcript files.
    public let outputRoot: URL

    // MARK: - Private state

    // Episodes injected at init (or from StateReader).
    private let episodes: [Episode]

    // MARK: - Initialisation

    /// Builds a `LibraryIndex` from an injected episode list and an output root.
    ///
    /// - Parameters:
    ///   - outputRoot: Root directory for library output (e.g. `~/Desktop/Vocateca/transcripts`).
    ///   - episodes: Episodes to index. Typically loaded via `StateReader.allEpisodes()`.
    public init(outputRoot: URL, episodes: [Episode]) {
        self.outputRoot = outputRoot
        self.episodes = episodes
    }

    /// Creates a `LibraryIndex` from a `Settings` value and `StateReader`.
    ///
    /// Convenience factory for production use. Resolves `settings.outputRoot`
    /// via tilde expansion, then loads all episodes from the reader.
    ///
    /// - Throws: Any error thrown by `StateReader.allEpisodes()`.
    public static func load(settings: Settings, reader: StateReader) throws -> LibraryIndex {
        let expandedRoot = (settings.outputRoot as NSString).expandingTildeInPath
        let outputRoot = URL(fileURLWithPath: expandedRoot, isDirectory: true)
        let episodes = try reader.allEpisodes()
        return LibraryIndex(outputRoot: outputRoot, episodes: episodes)
    }

    // MARK: - Public API

    /// Returns all episodes joined with their transcript file URLs.
    ///
    /// Performs the filesystem scan on each call; suitable for one-shot use.
    /// For repeated queries, cache the result array yourself.
    ///
    /// Missing files and missing show directories are tolerated: episodes
    /// without a matching transcript file get `transcriptURL = nil`.
    public func indexedEpisodes() -> [IndexedEpisode] {
        // Build a per-show-slug lookup: filename stem → URL
        let slugToURL = buildFileLookup()

        // Build guid→URL and per-show normalizedTitle→URL from frontmatter (one pass).
        let (guidToURL, titleToURL) = buildFrontmatterLookups(slugToURL: slugToURL)

        return episodes.map { ep in
            let slug = MarkdownLibraryWriter.makeSlug(ep)
            let showDir = ep.showSlug

            // 1. Try slug-based match within the show directory.
            if let url = slugToURL[showDir]?[slug] {
                return IndexedEpisode(episode: ep, transcriptURL: url)
            }

            // 2. Try GUID-based match (handles older transcripts with different slugs).
            if let url = guidToURL[ep.guid] {
                return IndexedEpisode(episode: ep, transcriptURL: url)
            }

            // 3. Try episode.transcriptPath (recorded in DB).
            if let tpStr = ep.transcriptPath {
                let url = URL(fileURLWithPath: tpStr)
                if FileManager.default.fileExists(atPath: url.path) {
                    return IndexedEpisode(episode: ep, transcriptURL: url)
                }
            }

            // 4. Title-based match within the show directory. v1 transcripts were
            //    written under a feed whose GUIDs differ from the re-subscribed v2
            //    feed, but the episode titles are identical — bridge them by title.
            if let url = titleToURL[showDir]?[Self.normalizedTitle(ep.title)] {
                return IndexedEpisode(episode: ep, transcriptURL: url)
            }

            return IndexedEpisode(episode: ep, transcriptURL: nil)
        }
    }

    /// Lowercased, alphanumerics-only title key for cross-feed matching.
    static func normalizedTitle(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// Returns indexed episodes grouped by show slug.
    public func episodesByShow() -> [String: [IndexedEpisode]] {
        Dictionary(grouping: indexedEpisodes(), by: { $0.episode.showSlug })
    }

    // MARK: - Private helpers

    /// Scans the output root and builds a two-level lookup:
    ///   `showSlug → [fileStem → URL]`
    ///
    /// Skips `index.md` files (matching the Python library convention).
    /// Tolerates missing/unreadable directories gracefully.
    private func buildFileLookup() -> [String: [String: URL]] {
        let fm = FileManager.default
        var result: [String: [String: URL]] = [:]

        guard fm.fileExists(atPath: outputRoot.path) else { return result }

        let showDirs: [URL]
        do {
            showDirs = try fm.contentsOfDirectory(
                at: outputRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return result
        }

        for showDir in showDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: showDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let slug = showDir.lastPathComponent
            var lookup: [String: URL] = [:]

            let mdFiles: [URL]
            do {
                mdFiles = try fm.contentsOfDirectory(
                    at: showDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
            } catch {
                continue
            }

            for file in mdFiles {
                lookup[file.deletingPathExtension().lastPathComponent] = file
            }

            result[slug] = lookup
        }

        return result
    }

    /// Reads YAML frontmatter from all .md files collected in `slugToURL` and
    /// builds a `guid → URL` mapping for GUID-based fallback lookup.
    ///
    /// Only reads the frontmatter block (first ~500 bytes) to keep this fast.
    private func buildGUIDLookup(slugToURL: [String: [String: URL]]) -> [String: URL] {
        buildFrontmatterLookups(slugToURL: slugToURL).guidToURL
    }

    /// Reads each .md's frontmatter once and returns both a flat `guid → URL` map
    /// and a per-show `normalizedTitle → URL` map (for the cross-feed title join).
    private func buildFrontmatterLookups(
        slugToURL: [String: [String: URL]]
    ) -> (guidToURL: [String: URL], titleToURL: [String: [String: URL]]) {
        var guidToURL: [String: URL] = [:]
        var titleToURL: [String: [String: URL]] = [:]
        for (showSlug, fileLookup) in slugToURL {
            for (_, url) in fileLookup {
                let fm = Self.extractFrontmatter(from: url)
                if let guid = fm["guid"], !guid.isEmpty { guidToURL[guid] = url }
                if let title = fm["title"], !title.isEmpty {
                    titleToURL[showSlug, default: [:]][Self.normalizedTitle(title)] = url
                }
            }
        }
        return (guidToURL, titleToURL)
    }

    /// Resolves the transcript `.md` for a SINGLE episode by scanning only its
    /// show directory (cheap enough to call per selection). Order: DB path →
    /// filename==slug → frontmatter guid → frontmatter title. Returns the `.md`
    /// URL, or nil when no match exists on disk.
    public static func resolveTranscriptURL(for episode: Episode, outputRoot: URL) -> URL? {
        if let tp = episode.transcriptPath {
            let u = URL(fileURLWithPath: tp)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // Re-slugify: episode.showSlug can originate from untrusted feed/import
        // data, so never trust it as a bare path component (traversal guard).
        let showDir = outputRoot.appendingPathComponent(
            TextNormalization.slugify(episode.showSlug), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: showDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }) else { return nil }

        let wantSlug = MarkdownLibraryWriter.makeSlug(episode)
        if let hit = files.first(where: { $0.deletingPathExtension().lastPathComponent == wantSlug }) {
            return hit
        }
        let wantTitle = normalizedTitle(episode.title)
        for f in files {
            let meta = extractFrontmatter(from: f)
            if let g = meta["guid"], g == episode.guid { return f }
            if let t = meta["title"], normalizedTitle(t) == wantTitle { return f }
        }
        return nil
    }

    /// Tries `resolveTranscriptURL(for:outputRoot:)` against each root in
    /// `candidateRoots`, in order, returning the first hit along with WHICH root
    /// resolved it. Used by the Library "transcript not found" recovery flow: the
    /// writer's canonical root is checked first, then a fallback (e.g. the
    /// user-configured `settings.outputRoot`) in case the library moved.
    ///
    /// - Returns: `(url, root)` for the first root that resolves the episode, or
    ///   `nil` if none of the candidates do.
    public static func resolveTranscriptURL(
        for episode: Episode, candidateRoots: [URL]
    ) -> (url: URL, root: URL)? {
        for root in candidateRoots {
            if let url = resolveTranscriptURL(for: episode, outputRoot: root) {
                return (url, root)
            }
        }
        return nil
    }

    /// Batch-resolves transcript URLs for MANY episodes at once.
    ///
    /// **Root cause this fixes (2026-07-16 Library-load-takes-minutes
    /// investigation):** the per-episode ``resolveTranscriptURL(for:candidateRoots:)``
    /// above re-lists the show's directory AND re-reads every file's YAML
    /// frontmatter for EVERY episode whose filename doesn't literally match
    /// its guid-based slug. On a real library, `episode.transcriptPath` is
    /// almost never persisted (measured: 3331/3360 "done" episodes, 99.1%,
    /// had an empty `transcript_path` column) and on-disk filenames are
    /// human-readable (`yyyy-mm-dd_title.md`, written under a user-configured
    /// output root) rather than the guid-slug the fast path expects — so
    /// EVERY resolution fell through to the frontmatter scan. For a show
    /// with ~650 transcripts (a real one in the repro library) needing ~650
    /// resolutions, that is up to ~650×650 ≈ 420,000 individual file opens +
    /// 2 KB reads for ONE show — the confirmed dominant cost behind the
    /// multi-minute "Loading your library…" hang (`LiveDataLoader.load()`
    /// awaits exactly this, once per show selection, via
    /// `LibraryViewModel.resolveHasTranscript`).
    ///
    /// This does the same directory listing + frontmatter read only ONCE per
    /// file (per show, per candidate root), then resolves every requested
    /// episode via O(1) dictionary lookups — O(files + episodes) instead of
    /// O(files × episodes). Same match order/semantics as the per-episode
    /// overload (DB path → filename==slug → frontmatter guid → frontmatter
    /// title), so callers see identical results, just computed cheaply.
    ///
    /// - Parameters:
    ///   - episodes: episodes to resolve — any mix of show slugs (grouped
    ///     internally so each show directory is scanned at most once).
    ///   - candidateRoots: roots to check IN ORDER (canonical root first,
    ///     then any user-configured fallback), matching the per-episode
    ///     overload's contract.
    ///   - onProgress: optional `(done, total)` tick, called as each episode
    ///     is accounted for (resolved OR exhausted with no match) — `total`
    ///     is fixed to `episodes.count` up front so a caller can drive a
    ///     determinate "N / total" progress UI. Defaults to a no-op; purely
    ///     a side-effect hook that never affects the return value.
    /// - Returns: `guid → URL` for every episode that resolved on ANY
    ///   candidate root. Episodes absent from the result have no transcript
    ///   on disk (or their show directory doesn't exist on any root).
    public static func resolveTranscriptURLs(
        for episodes: [Episode],
        candidateRoots: [URL],
        onProgress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) -> [String: URL] {
        var result: [String: URL] = [:]
        let total = episodes.count
        guard total > 0 else { return result }
        var done = 0

        // 1. DB-recorded path first — cheapest check, no directory scan.
        var remaining: [Episode] = []
        remaining.reserveCapacity(episodes.count)
        let fm = FileManager.default
        for ep in episodes {
            if let tp = ep.transcriptPath {
                let u = URL(fileURLWithPath: tp)
                if fm.fileExists(atPath: u.path) {
                    result[ep.guid] = u
                    done += 1
                    onProgress(done, total)
                    continue
                }
            }
            remaining.append(ep)
        }
        guard !remaining.isEmpty else { return result }

        // 2. Group the rest by show slug so each show directory is scanned
        //    (and its files' frontmatter read) ONCE per candidate root, no
        //    matter how many of that show's episodes need resolving.
        let bySlug = Dictionary(grouping: remaining, by: \.showSlug)

        for (showSlug, epsInShow) in bySlug {
            var unresolved = epsInShow
            for root in candidateRoots {
                guard !unresolved.isEmpty else { break }
                // Re-slugify: showSlug can originate from untrusted feed/import
                // data, so never trust it as a bare path component (traversal
                // guard) — mirrors the per-episode overload.
                let showDir = root.appendingPathComponent(
                    TextNormalization.slugify(showSlug), isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(
                    at: showDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).filter({ $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }),
                !files.isEmpty else { continue }

                // Filename-stem → URL, built once for this directory.
                var slugToURL: [String: URL] = [:]
                slugToURL.reserveCapacity(files.count)
                for f in files { slugToURL[f.deletingPathExtension().lastPathComponent] = f }

                // guid → URL / normalizedTitle → URL from frontmatter — ALSO
                // built once (one open + 2 KB read per FILE, not per episode).
                var guidToURL: [String: URL] = [:]
                var titleToURL: [String: URL] = [:]
                guidToURL.reserveCapacity(files.count)
                for f in files {
                    let meta = extractFrontmatter(from: f)
                    if let g = meta["guid"], !g.isEmpty { guidToURL[g] = f }
                    if let t = meta["title"], !t.isEmpty { titleToURL[normalizedTitle(t)] = f }
                }

                var stillUnresolved: [Episode] = []
                for ep in unresolved {
                    let wantSlug = MarkdownLibraryWriter.makeSlug(ep)
                    if let url = slugToURL[wantSlug] {
                        result[ep.guid] = url
                    } else if let url = guidToURL[ep.guid] {
                        result[ep.guid] = url
                    } else if let url = titleToURL[normalizedTitle(ep.title)] {
                        result[ep.guid] = url
                    } else {
                        stillUnresolved.append(ep)
                        continue
                    }
                    done += 1
                    onProgress(done, total)
                }
                unresolved = stillUnresolved
            }
            // Episodes that exhausted every candidate root without a match
            // still count as "processed" for progress purposes.
            if !unresolved.isEmpty {
                done += unresolved.count
                onProgress(done, total)
            }
        }

        return result
    }

    /// Extracts scalar fields from the YAML frontmatter (`---` block) at the top
    /// of the file (only `guid` + `title` are needed). Simple line scan, no YAML
    /// dependency. Returns an empty dict when there's no frontmatter.
    public static func extractFrontmatter(from url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }

        // Read first 2 KB — frontmatter is always at the top.
        let data = handle.readData(ofLength: 2048)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("---") else { return [:] }

        var fields: [String: String] = [:]
        var inFrontmatter = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter { inFrontmatter = true; continue } else { break }
            }
            guard inFrontmatter else { continue }
            for key in ["guid", "title", "transcribed_at"] where trimmed.hasPrefix("\(key):") {
                let value = trimmed.dropFirst("\(key):".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { fields[key] = value }
            }
        }
        return fields
    }
}
