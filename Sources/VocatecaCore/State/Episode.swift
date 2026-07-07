@preconcurrency import GRDB

/// The canonical domain model for a Vocateca episode.
///
/// Maps directly onto the `episodes` table in both the v1 (Python-managed)
/// production database and v2 (Swift-owned) databases. This single type works
/// against **both** schema versions:
///
/// - Against a **v1 database** (no v2 columns): `init(row:)` reads v2 columns
///   only when they are present (`row.hasColumn(_:)`), leaving them `nil`.
///   This means `StateReader` can decode `Episode` values from the live
///   production file without a migration.
///
/// - Against a **v2 database** (after `Schema.migrator` runs): all columns
///   are present and v2 fields are populated as written.
///
/// `EpisodeRow` is kept as a typealias for source compatibility with the
/// Spike A code in `StateReader`. New call sites should prefer `Episode`.
public struct Episode: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {

    // MARK: - GRDB metadata

    public static let databaseTableName = "episodes"

    // MARK: - v1 columns (always present in production)

    public var guid: String
    public var showSlug: String
    public var title: String
    public var pubDate: String
    public var mp3Url: String
    public var status: String
    public var mp3Path: String?
    public var transcriptPath: String?
    public var attemptedAt: String?
    public var completedAt: String?
    public var errorText: String?
    public var durationSec: Int?
    public var wordCount: Int?
    public var priority: Int
    public var detectedLanguage: String?
    public var meanConfidence: Double?
    public var errorCategory: String?
    public var attempts: Int

    // MARK: - v2 columns (nil when reading from a v1 database)

    public var description: String?
    public var igShortcode: String?
    public var igProfile: String?
    public var igKind: String?
    public var mediaType: String?
    public var ocrText: String?
    public var imageTags: String?
    /// How the transcript was derived (see ``TranscriptOrigin/storageString``):
    /// `"captions:auto"`, `"captions:manual"`, `"whisper:<model>"`, or `"ocr"`.
    public var transcriptOrigin: String?

    // MARK: - Memberwise initialiser

    public init(
        guid: String,
        showSlug: String,
        title: String,
        pubDate: String,
        mp3Url: String,
        status: String = "pending",
        mp3Path: String? = nil,
        transcriptPath: String? = nil,
        attemptedAt: String? = nil,
        completedAt: String? = nil,
        errorText: String? = nil,
        durationSec: Int? = nil,
        wordCount: Int? = nil,
        priority: Int = 0,
        detectedLanguage: String? = nil,
        meanConfidence: Double? = nil,
        errorCategory: String? = nil,
        attempts: Int = 0,
        description: String? = nil,
        igShortcode: String? = nil,
        igProfile: String? = nil,
        igKind: String? = nil,
        mediaType: String? = nil,
        ocrText: String? = nil,
        imageTags: String? = nil,
        transcriptOrigin: String? = nil
    ) {
        self.guid = guid
        self.showSlug = showSlug
        self.title = title
        self.pubDate = pubDate
        self.mp3Url = mp3Url
        self.status = status
        self.mp3Path = mp3Path
        self.transcriptPath = transcriptPath
        self.attemptedAt = attemptedAt
        self.completedAt = completedAt
        self.errorText = errorText
        self.durationSec = durationSec
        self.wordCount = wordCount
        self.priority = priority
        self.detectedLanguage = detectedLanguage
        self.meanConfidence = meanConfidence
        self.errorCategory = errorCategory
        self.attempts = attempts
        self.description = description
        self.igShortcode = igShortcode
        self.igProfile = igProfile
        self.igKind = igKind
        self.mediaType = mediaType
        self.ocrText = ocrText
        self.imageTags = imageTags
        self.transcriptOrigin = transcriptOrigin
    }

    // MARK: - FetchableRecord (custom init to handle v1 / v2 column presence)

    /// Decodes a GRDB `Row` into an `Episode`.
    ///
    /// v2 columns are read defensively: if the column is absent (i.e. a v1
    /// database opened without running the Swift migration), the field is set
    /// to `nil` rather than throwing. This makes one `Episode` type work
    /// against both schema versions without any conditional branching at the
    /// call site.
    public init(row: Row) throws {
        guid             = row["guid"]
        showSlug         = row["show_slug"]
        title            = row["title"]
        pubDate          = row["pub_date"]
        mp3Url           = row["mp3_url"]
        status           = row["status"]
        mp3Path          = row["mp3_path"]
        transcriptPath   = row["transcript_path"]
        attemptedAt      = row["attempted_at"]
        completedAt      = row["completed_at"]
        errorText        = row["error_text"]
        durationSec      = row["duration_sec"]
        wordCount        = row["word_count"]
        priority         = row["priority"] ?? 0
        detectedLanguage = row["detected_language"]
        meanConfidence   = row["mean_confidence"]
        errorCategory    = row["error_category"]
        attempts         = row["attempts"] ?? 0

        // v2 columns — only read when the column actually exists in this DB.
        description  = row.hasColumn("description")   ? row["description"]   : nil
        igShortcode  = row.hasColumn("ig_shortcode")  ? row["ig_shortcode"]  : nil
        igProfile    = row.hasColumn("ig_profile")    ? row["ig_profile"]    : nil
        igKind       = row.hasColumn("ig_kind")       ? row["ig_kind"]       : nil
        mediaType    = row.hasColumn("media_type")    ? row["media_type"]    : nil
        ocrText      = row.hasColumn("ocr_text")      ? row["ocr_text"]      : nil
        imageTags    = row.hasColumn("image_tags")    ? row["image_tags"]    : nil
        transcriptOrigin = row.hasColumn("transcript_origin") ? row["transcript_origin"] : nil
    }

    // MARK: - PersistableRecord (encode back to snake_case columns)

    public func encode(to container: inout PersistenceContainer) throws {
        container["guid"]              = guid
        container["show_slug"]         = showSlug
        container["title"]             = title
        container["pub_date"]          = pubDate
        container["mp3_url"]           = mp3Url
        container["status"]            = status
        container["mp3_path"]          = mp3Path
        container["transcript_path"]   = transcriptPath
        container["attempted_at"]      = attemptedAt
        container["completed_at"]      = completedAt
        container["error_text"]        = errorText
        container["duration_sec"]      = durationSec
        container["word_count"]        = wordCount
        container["priority"]          = priority
        container["detected_language"] = detectedLanguage
        container["mean_confidence"]   = meanConfidence
        container["error_category"]    = errorCategory
        container["attempts"]          = attempts
        container["description"]       = description
        container["ig_shortcode"]      = igShortcode
        container["ig_profile"]        = igProfile
        container["ig_kind"]           = igKind
        container["media_type"]        = mediaType
        container["ocr_text"]          = ocrText
        container["image_tags"]        = imageTags
        container["transcript_origin"] = transcriptOrigin
    }
}

// MARK: - Source-compatibility alias

/// `EpisodeRow` is preserved as a typealias for call sites written during
/// Spike A. All new code should use `Episode` directly.
///
/// `Episode` replaces the former `struct EpisodeRow` because it adds
/// `PersistableRecord` + `Equatable` + v2 fields while remaining a drop-in
/// for every place that previously read `EpisodeRow` values.
public typealias EpisodeRow = Episode
