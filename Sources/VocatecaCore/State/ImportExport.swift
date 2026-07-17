import Foundation

// MARK: - Export container

/// The versioned container written to / read from an export file.
///
/// Format: JSON with a header block identifying the app + kind + schema version,
/// and an opaque `payload` field that holds the real data.
///
/// Two kinds are defined:
///   - `"settings"` — payload contains a ``Settings`` value.
///   - `"subscriptions"` — payload contains a ``Watchlist`` (the `shows` array).
///
/// `exportedAt` is an ISO-8601 timestamp string. It is injected by the caller so
/// that testable code never calls `Date()` directly.
public struct ExportEnvelope: Codable, Sendable {

    // MARK: Header

    /// Application identifier — always `"vocateca"`.
    public let app: String
    /// Payload discriminator: `"settings"` or `"subscriptions"`.
    public let kind: ExportKind
    /// Schema version. Increment when the payload shape changes incompatibly.
    /// Currently `1`.
    public let version: Int
    /// ISO-8601 timestamp string, supplied by the caller (never from `Date()`
    /// directly, for testability).
    public let exportedAt: String
    /// Raw JSON payload. We store it as a nested JSON object so the decoder can
    /// read the header fields before attempting to decode the payload.
    public let payload: ExportPayload

    public init(app: String = "vocateca",
                kind: ExportKind,
                version: Int = 1,
                exportedAt: String,
                payload: ExportPayload) {
        self.app = app
        self.kind = kind
        self.version = version
        self.exportedAt = exportedAt
        self.payload = payload
    }
}

/// The discriminator values for ``ExportEnvelope/kind``.
public enum ExportKind: String, Codable, Sendable {
    case settings
    case subscriptions
    case full
}

/// A lightweight, exportable projection of ``Episode``.
///
/// Deliberately excludes any transcript body / OCR text / large blobs — only
/// metadata plus the on-disk `transcriptPath` (so the user can locate the
/// actual transcript file, which stays in their output folder).
public struct EpisodeExport: Codable, Sendable, Equatable {
    public let guid: String
    public let showSlug: String
    public let title: String
    public let status: String
    public let pubDate: String
    public let completedAt: String?
    public let transcriptPath: String?

    public init(guid: String, showSlug: String, title: String, status: String,
                pubDate: String, completedAt: String?, transcriptPath: String?) {
        self.guid = guid
        self.showSlug = showSlug
        self.title = title
        self.status = status
        self.pubDate = pubDate
        self.completedAt = completedAt
        self.transcriptPath = transcriptPath
    }

    /// Project a full ``Episode`` down to its exportable metadata.
    public init(_ episode: Episode) {
        self.guid = episode.guid
        self.showSlug = episode.showSlug
        self.title = episode.title
        self.status = episode.status
        self.pubDate = episode.pubDate
        self.completedAt = episode.completedAt
        self.transcriptPath = episode.transcriptPath
    }
}

/// The "export everything" payload: settings (redacted) + subscriptions +
/// lightweight episode metadata. Written as a single JSON file so a user can
/// download "all my data" in one action.
public struct FullExportPayload: Codable, Sendable {
    public let settings: Settings
    public let subscriptions: Watchlist
    public let episodes: [EpisodeExport]

    public init(settings: Settings, subscriptions: Watchlist, episodes: [EpisodeExport]) {
        self.settings = settings
        self.subscriptions = subscriptions
        self.episodes = episodes
    }
}

/// The payload union type.
public enum ExportPayload: Codable, Sendable {

    case settings(Settings)
    case subscriptions(Watchlist)
    case full(FullExportPayload)

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type
        case settings
        case subscriptions
        case full
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .settings(let s):
            try c.encode("settings", forKey: .type)
            try c.encode(s, forKey: .settings)
        case .subscriptions(let wl):
            try c.encode("subscriptions", forKey: .type)
            try c.encode(wl, forKey: .subscriptions)
        case .full(let bundle):
            try c.encode("full", forKey: .type)
            try c.encode(bundle, forKey: .full)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "settings":
            let s = try c.decode(Settings.self, forKey: .settings)
            self = .settings(s)
        case "subscriptions":
            let wl = try c.decode(Watchlist.self, forKey: .subscriptions)
            self = .subscriptions(wl)
        case "full":
            let bundle = try c.decode(FullExportPayload.self, forKey: .full)
            self = .full(bundle)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown payload type: \(type)"
            )
        }
    }
}

// MARK: - ImportExportError

/// Errors thrown by the export/import service.
public enum ImportExportError: Error, LocalizedError {
    case wrongApp(String)
    case wrongKind(expected: ExportKind, got: ExportKind)
    case unsupportedVersion(Int)
    case payloadMismatch
    case encodingFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongApp(let name):
            return "This file was exported from '\(name)', not vocateca."
        case .wrongKind(let expected, let got):
            return "Expected a \(expected.rawValue) export file, but got a \(got.rawValue) file."
        case .unsupportedVersion(let v):
            return "Export file version \(v) is not supported by this version of vocateca."
        case .payloadMismatch:
            return "The file's payload does not match its declared kind."
        case .encodingFailed(let detail):
            return "Could not encode export data: \(detail)"
        case .decodingFailed(let detail):
            return "Could not read the import file: \(detail)"
        }
    }
}

// MARK: - ImportExportService

/// Pure, testable core for export / import of settings and subscriptions.
///
/// All functions are static — no mutable state; all file I/O is deferred to
/// the `apply…` helpers so the diff/encode functions are unit-testable without
/// touching the filesystem.
public enum ImportExportService {

    // MARK: - Supported version range

    public static let currentVersion = 1
    public static let minimumSupportedVersion = 1
    public static let maximumSupportedVersion = 1

    // MARK: - Encode

    /// Encode `settings` into an export `Data` (JSON).
    ///
    /// - Parameter exportedAt: ISO-8601 timestamp string. Supply `Date().iso8601` in
    ///   production; a fixed string in tests.
    public static func encodeSettings(_ settings: Settings, exportedAt: String) throws -> Data {
        let redacted = redactedSettings(settings)

        let envelope = ExportEnvelope(
            kind: .settings,
            exportedAt: exportedAt,
            payload: .settings(redacted)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw ImportExportError.encodingFailed(error.localizedDescription)
        }
    }

    /// Redact webhook signing secrets before `settings` ever leaves the app.
    ///
    /// An export file is a plain-text artifact the user may email, upload,
    /// or store in a synced folder — HMAC secrets must never travel with it.
    /// Shared by ``encodeSettings(_:exportedAt:)`` and
    /// ``encodeFullBundle(settings:watchlist:episodes:exportedAt:)`` so every
    /// export path redacts the same way.
    private static func redactedSettings(_ settings: Settings) -> Settings {
        var redacted = settings
        var redactedCount = 0
        for i in redacted.webhooks.indices where !redacted.webhooks[i].secret.isEmpty {
            redacted.webhooks[i].secret = ""
            redactedCount += 1
        }
        if redactedCount > 0 {
            Log.info("ImportExport: redacted webhook secrets from export",
                     component: "ImportExport", context: [("count", "\(redactedCount)")])
        }
        return redacted
    }

    /// Encode `watchlist` into an export `Data` (JSON).
    public static func encodeSubscriptions(_ watchlist: Watchlist, exportedAt: String) throws -> Data {
        let envelope = ExportEnvelope(
            kind: .subscriptions,
            exportedAt: exportedAt,
            payload: .subscriptions(watchlist)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw ImportExportError.encodingFailed(error.localizedDescription)
        }
    }

    /// Encode a single "export all my data" bundle: settings (webhook secrets
    /// redacted), subscriptions, and lightweight episode metadata.
    ///
    /// Transcript FILES themselves are not included — only ``EpisodeExport``
    /// metadata (including `transcriptPath`, which points at the file already
    /// living in the user's output folder).
    ///
    /// - Parameter exportedAt: ISO-8601 timestamp string. Supply `Date().iso8601`
    ///   in production; a fixed string in tests.
    public static func encodeFullBundle(
        settings: Settings,
        watchlist: Watchlist,
        episodes: [Episode],
        exportedAt: String
    ) throws -> Data {
        let redacted = redactedSettings(settings)
        let episodeExports = episodes.map(EpisodeExport.init)

        let bundle = FullExportPayload(
            settings: redacted,
            subscriptions: watchlist,
            episodes: episodeExports
        )
        let envelope = ExportEnvelope(
            kind: .full,
            exportedAt: exportedAt,
            payload: .full(bundle)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw ImportExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Decode

    /// Decode and validate an import file's `Data`.
    ///
    /// Validates: `app == "vocateca"`, `version` in supported range.
    /// Returns the typed ``ExportEnvelope``.
    public static func decodeEnvelope(from data: Data) throws -> ExportEnvelope {
        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(ExportEnvelope.self, from: data)
            guard envelope.app == "vocateca" else {
                throw ImportExportError.wrongApp(envelope.app)
            }
            guard envelope.version >= minimumSupportedVersion,
                  envelope.version <= maximumSupportedVersion else {
                throw ImportExportError.unsupportedVersion(envelope.version)
            }
            return envelope
        } catch let err as ImportExportError {
            throw err
        } catch {
            throw ImportExportError.decodingFailed(error.localizedDescription)
        }
    }

    /// Decode a settings export file, validating that it is a `.settings` kind.
    public static func decodeSettings(from data: Data) throws -> Settings {
        let envelope = try decodeEnvelope(from: data)
        guard envelope.kind == .settings else {
            throw ImportExportError.wrongKind(expected: .settings, got: envelope.kind)
        }
        guard case .settings(let s) = envelope.payload else {
            throw ImportExportError.payloadMismatch
        }
        return s
    }

    /// Decode a subscriptions export file, validating that it is a `.subscriptions` kind.
    public static func decodeSubscriptions(from data: Data) throws -> Watchlist {
        let envelope = try decodeEnvelope(from: data)
        guard envelope.kind == .subscriptions else {
            throw ImportExportError.wrongKind(expected: .subscriptions, got: envelope.kind)
        }
        guard case .subscriptions(let wl) = envelope.payload else {
            throw ImportExportError.payloadMismatch
        }
        return wl
    }

    // MARK: - Settings diff

    /// A single field that differs between the imported and current settings.
    public struct SettingsFieldDiff: Sendable, Identifiable {
        public let id: String
        /// Human-readable field label.
        public let label: String
        /// The current (on-disk) value rendered as a string.
        public let oldValue: String
        /// The incoming (imported) value rendered as a string.
        public let newValue: String

        public init(id: String, label: String, oldValue: String, newValue: String) {
            self.id = id
            self.label = label
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    /// Compare `imported` vs `current` field-by-field.
    ///
    /// Returns only the fields that differ. Fields whose change is typically
    /// user-invisible (e.g. entitlement caches, upsell timestamps, disclaimers)
    /// are included so the user sees the full picture, but you can filter them
    /// in the UI if needed.
    ///
    /// Pure function — no I/O, easily testable.
    public static func diffSettings(imported: Settings, current: Settings) -> [SettingsFieldDiff] {
        var diffs: [SettingsFieldDiff] = []

        func check<T: Equatable>(_ label: String, _ id: String, _ kp: KeyPath<Settings, T>,
                                  _ render: (T) -> String = { "\($0)" }) {
            let old = current[keyPath: kp]
            let new = imported[keyPath: kp]
            if old != new {
                diffs.append(SettingsFieldDiff(id: id, label: label,
                                               oldValue: render(old),
                                               newValue: render(new)))
            }
        }

        // Output & Library
        check("Output folder",       "outputRoot",                   \.outputRoot)
        check("Export root",         "exportRoot",                   \.exportRoot)
        check("Obsidian vault path", "obsidianVaultPath",            \.obsidianVaultPath)
        check("Obsidian vault name", "obsidianVaultName",            \.obsidianVaultName)
        check("Save SRT",            "saveSrt",                      \.saveSrt)
        check("MP3 retention days",  "mp3RetentionDays",             \.mp3RetentionDays)
        check("Delete MP3 after transcribe", "deleteMp3AfterTranscribe", \.deleteMp3AfterTranscribe)
        check("Transcript retention days", "transcriptRetentionDays", \.transcriptRetentionDays)

        // Mode & performance
        check("Startup mode",        "defaultStartupMode",           \.defaultStartupMode)
        check("Power revert policy", "powerRevertPolicy",            \.powerRevertPolicy)
        check("Load level",          "loadLevel",                    \.loadLevel)

        // Transcription
        check("Whisper model",       "whisperModel",                 \.whisperModel)
        check("Whisper fast mode",   "whisperFastMode",              \.whisperFastMode)
        check("Whisper Metal",       "whisperMetalEnabled",          \.whisperMetalEnabled)
        check("Whisper autopick",    "whisperModelAutopick",         \.whisperModelAutopick)
        check("Transcribe concurrency", "transcribeConcurrency",     \.transcribeConcurrency)
        check("Diarization",         "diarizationEnabled",           \.diarizationEnabled)
        check("Diarization model dir", "diarizationModelDir",        \.diarizationModelDir)

        // Sources — Podcasts
        check("Podcasts",            "sourcesPodcasts",              \.sourcesPodcasts)

        // Sources — YouTube
        check("YouTube",             "sourcesYoutube",               \.sourcesYoutube)
        check("Default: Videos",     "youtubeIncludeVideosDefault",  \.youtubeIncludeVideosDefault)
        check("Default: Shorts",     "youtubeSkipShortsDefault",     \.youtubeSkipShortsDefault)
        check("Transcript source",   "youtubeDefaultTranscriptSource", \.youtubeDefaultTranscriptSource)
        check("Default language",    "youtubeDefaultLanguage",       \.youtubeDefaultLanguage)

        // Sources — Instagram
        check("Instagram",           "sourcesInstagram",             \.sourcesInstagram)
        check("Instagram fetch interval (min)", "instagramFetchIntervalMinutes", \.instagramFetchIntervalMinutes)
        check("Instagram stories interval (min)", "instagramStoriesIntervalMinutes", \.instagramStoriesIntervalMinutes)
        check("IG default reels",    "igDefaultReels",               \.igDefaultReels)
        check("IG default posts",    "igDefaultPosts",               \.igDefaultPosts)
        check("IG default stories",  "igDefaultStories",             \.igDefaultStories)

        // Schedule & Automation
        check("Daily check",         "dailyCheckEnabled",            \.dailyCheckEnabled)
        check("Daily check time",    "dailyCheckTime",               \.dailyCheckTime)
        check("Catch up missed",     "catchUpMissed",                \.catchUpMissed)
        check("Auto-start queue",    "autoStartQueue",               \.autoStartQueue)
        check("Auto-start delay (s)", "autoStartDelaySeconds",       \.autoStartDelaySeconds)
        check("Daily summary",       "dailySummary",                 \.dailySummary)

        // Folder watch
        check("Folder watch",        "watchFolderEnabled",           \.watchFolderEnabled)
        check("Watch folder path",   "watchFolderRoot",              \.watchFolderRoot)
        check("Watch folder post",   "watchFolderPost",              \.watchFolderPost)

        // Notifications
        check("Notify on success",   "notifyOnSuccess",              \.notifyOnSuccess)
        check("Notify mode",         "notifyMode",                   \.notifyMode)
        check("Quiet hours",         "notifyQuietHoursEnabled",      \.notifyQuietHoursEnabled)
        check("Quiet hours start",   "notifyQuietHoursStart",        \.notifyQuietHoursStart)
        check("Quiet hours end",     "notifyQuietHoursEnd",          \.notifyQuietHoursEnd)
        check("Daily summary notify","dailySummary",                 \.dailySummary)
        check("Keyword watch",       "keywordWatch", \.keywordWatch) { (kw: [WatchTerm]) in kw.map(\.term).joined(separator: ", ") }

        // Bandwidth / disk
        check("Bandwidth limit (Mbps)", "bandwidthLimitMbps",       \.bandwidthLimitMbps)
        check("RSS concurrency",     "rssConcurrency",               \.rssConcurrency)
        check("Download concurrency","downloadConcurrency",          \.downloadConcurrency)
        check("Disk guard",          "diskGuardEnabled",             \.diskGuardEnabled)
        check("Disk guard min free (GB)", "diskGuardMinFreeGb",      \.diskGuardMinFreeGb)
        check("Low-disk HUD threshold (GB)",   "diskWarnHudGb",      \.diskWarnHudGb)
        check("Low-disk modal threshold (GB)", "diskWarnModalGb",    \.diskWarnModalGb)

        // Deduplicate by id (keywordWatch appears twice due to both being notif and general)
        var seen = Set<String>()
        return diffs.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Subscriptions diff

    /// Classification of a single show in the subscriptions diff.
    public enum ShowDiffStatus: Sendable {
        /// In the import file, not in the current watchlist (will be added on merge or overwrite).
        case added
        /// In both; at least one field differs (imported value wins on merge or overwrite).
        case changed
        /// In both; all fields identical.
        case unchanged
        /// In the current watchlist but not in the import file.
        /// Only visible / relevant in the "overwrite" scenario.
        case removed
    }

    /// The diff result for a single show.
    public struct ShowDiff: Sendable, Identifiable {
        public let id: String       // = slug
        public let slug: String
        public let title: String
        public let status: ShowDiffStatus

        public init(slug: String, title: String, status: ShowDiffStatus) {
            self.id = slug
            self.slug = slug
            self.title = title
            self.status = status
        }
    }

    /// Compare `imported` watchlist against `current` watchlist.
    ///
    /// Returns a list of ``ShowDiff`` entries sorted by status (added → changed → unchanged → removed).
    ///
    /// Pure function — no I/O, easily testable.
    public static func diffSubscriptions(imported: Watchlist, current: Watchlist) -> [ShowDiff] {
        let importedBySlug = Dictionary(uniqueKeysWithValues: imported.shows.map { ($0.slug, $0) })
        let currentBySlug  = Dictionary(uniqueKeysWithValues: current.shows.map  { ($0.slug, $0) })

        var result: [ShowDiff] = []

        // Walk import list: added or changed/unchanged vs current
        for show in imported.shows {
            if let cur = currentBySlug[show.slug] {
                let status: ShowDiffStatus = (cur == show) ? .unchanged : .changed
                result.append(ShowDiff(slug: show.slug, title: show.title, status: status))
            } else {
                result.append(ShowDiff(slug: show.slug, title: show.title, status: .added))
            }
        }

        // Walk current list: find removed (in current, not in import)
        for show in current.shows where importedBySlug[show.slug] == nil {
            result.append(ShowDiff(slug: show.slug, title: show.title, status: .removed))
        }

        // Sort: added → changed → unchanged → removed
        let order: [ShowDiffStatus: Int] = [.added: 0, .changed: 1, .unchanged: 2, .removed: 3]
        result.sort { (order[$0.status] ?? 99) < (order[$1.status] ?? 99) }

        return result
    }

    // MARK: - Merge helpers

    /// Compute the resulting show list for a MERGE operation.
    ///
    /// Rules: current shows ∪ imported shows; imported value wins on slug collisions.
    ///
    /// Pure function — no I/O.
    public static func mergeSubscriptions(imported: Watchlist, current: Watchlist) -> Watchlist {
        var bySlug: [(String, Show)] = current.shows.map { ($0.slug, $0) }
        var slugOrder: [String] = current.shows.map { $0.slug }

        for show in imported.shows {
            if let idx = bySlug.firstIndex(where: { $0.0 == show.slug }) {
                bySlug[idx] = (show.slug, show)     // imported wins
            } else {
                bySlug.append((show.slug, show))
                slugOrder.append(show.slug)
            }
        }

        let merged = slugOrder.compactMap { slug in bySlug.first(where: { $0.0 == slug })?.1 }
        return Watchlist(shows: merged)
    }

    // MARK: - Apply (file I/O)

    /// Write `settings` atomically to `url` (defaults to ``Paths/settingsURL``).
    ///
    /// Uses a `.tmp` sibling + `FileManager.replaceItemAt` for crash-safety.
    public static func applySettings(_ settings: Settings, to url: URL = Paths.settingsURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        let text = try SettingsStore.yamlString(settings)
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Write `watchlist` atomically to `url` (defaults to ``Paths/watchlistURL``).
    public static func applySubscriptions(
        _ watchlist: Watchlist,
        mode: SubscriptionImportMode,
        current: Watchlist,
        to url: URL = Paths.watchlistURL
    ) throws {
        // An import file is untrusted input — re-slugify every imported show's
        // slug before it can reach `watchlist.yaml`. Without this, a crafted
        // slug (e.g. containing "../") could traverse out of the library/media
        // directories that are built from `show.slug` downstream.
        let sanitizedWatchlist = Watchlist(
            shows: watchlist.shows.map { show in
                var s = show
                s.slug = TextNormalization.slugify(show.slug)
                return s
            }
        )

        let resultWatchlist: Watchlist
        switch mode {
        case .overwrite:
            resultWatchlist = sanitizedWatchlist
        case .merge:
            resultWatchlist = mergeSubscriptions(imported: sanitizedWatchlist, current: current)
        }
        try resultWatchlist.saveAtomic(to: url)
    }
}

// MARK: - SubscriptionImportMode

/// Controls how the imported subscriptions are combined with the existing ones.
public enum SubscriptionImportMode: Sendable {
    /// Replace the entire watchlist with the imported set (removes shows not in import).
    case overwrite
    /// Add/update imported shows, keeping existing shows that are not in the import.
    case merge
}

// MARK: - Date ISO-8601 helper

extension Date {
    /// ISO-8601 UTC string suitable for ``ExportEnvelope/exportedAt``.
    public var iso8601: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: self)
    }
}
