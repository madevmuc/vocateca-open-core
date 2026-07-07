import Foundation
import Yams

// MARK: - Show

/// A single podcast / YouTube channel / local-folder show entry.
///
/// Oracle-locked field-for-field port of `core/models.py :: Show`.
/// Every field matches the Python Pydantic model in name (as YAML key),
/// type, and **default value** — critical for the live-oracle parity test.
///
/// v2-only additions (``igReels``, ``igPosts``, etc.) are appended at the
/// bottom with no-op defaults so existing YAML files load without error.
public struct Show: Codable, Sendable, Equatable {

    // MARK: Required fields (no defaults in Python)
    public var slug: String
    public var title: String
    public var rss: String

    // MARK: Optional / defaulted fields (Python model order preserved)
    public var whisperPrompt: String
    public var enabled: Bool
    /// True for a "one-off" pseudo-show — a single manually-added item (Transcribe
    /// once / drag-drop / folder / URL import) that has no pollable feed behind it.
    /// Persisted so the identity survives a watchlist round-trip: a one-off is
    /// never monitored, offers no subscribe/auto-download toggles, and is removed
    /// when its last episode is deleted. Defaults to `false` (a real subscription).
    public var oneOff: Bool
    public var outputOverride: String?
    public var language: String
    public var artworkUrl: String
    public var source: String
    public var youtubeTranscriptPref: String
    public var skipShorts: Bool
    public var includeVideos: Bool
    public var autoVocab: Bool
    public var minDurationSec: Int
    public var maxDurationSec: Int
    public var notify: Bool

    // MARK: v2-only — music-detection opt-out
    /// When `true` (default), the show is assumed to contain speech, so the
    /// no-speech / music-detection **skip** is bypassed in the pipeline — an
    /// episode the detector flags as music/instrumental is transcribed anyway
    /// (a jingle may just have been a false positive) and produces no
    /// "skipped — no speech" notification. When `false`, the current
    /// auto-detect behaviour applies (the detector may skip music episodes).
    public var assumeSpeech: Bool

    // MARK: v2-only additions (ig sources)
    public var igReels: Bool
    public var igPosts: Bool
    public var igStories: Bool
    public var igBackfillMode: String
    public var igBackfillN: Int

    // MARK: v2-only — unified backfill policy (podcast + YouTube + Instagram)
    /// Import-scope mode; see ``BackfillMode``. Stored as the raw string so
    /// unknown/legacy values round-trip through YAML without decode failure.
    public var backfillMode: String
    /// "Last N" item count, used only when `backfillMode == "last_n"`.
    public var backfillN: Int
    /// ISO date `YYYY-MM-DD` (or empty), used only when `backfillMode == "since_date"`.
    public var backfillSince: String
    /// Per-show media-retention override (days). Sentinels: `-1` = follow the
    /// global `Settings.mp3RetentionDays`/`deleteMp3AfterTranscribe`; `0` = keep
    /// media forever (never reclaim); `N>0` = delete media N days after transcribe.
    /// Transcripts are never affected.
    public var mediaRetentionOverrideDays: Int

    // MARK: v2-only — author / publisher
    /// Author or publisher name from the feed metadata (e.g. iTunes `artistName`,
    /// RSS `<itunes:author>`, YouTube channel name / @handle).
    /// nil when not yet populated or not available (e.g. Instagram — deferred).
    public var author: String?

    // MARK: v2-only — explicit creator assignment
    /// The creator name this show is explicitly assigned to.
    /// When nil/empty the aggregator falls back to title-root heuristics.
    public var creator: String?

    // MARK: v2-only — user-overridable display name
    /// A user-chosen override for the show's display name. When nil/empty the
    /// effective name falls back to the feed `title` (see ``displayName``).
    /// Renaming to an empty string CLEARS this override.
    public var customTitle: String?

    // MARK: v2-only — subscription date
    /// ISO date (YYYY-MM-DD) when the show was first added. Pre-existing shows read
    /// the sentinel ``defaultAddedAt`` (a fixed past date) so they never count as
    /// "New"; a freshly added show is stamped with today's date.
    public var addedAt: String

    // MARK: - Defaults

    public static let defaultWhisperPrompt = ""
    public static let defaultEnabled = true
    /// Pre-existing shows (no key in YAML) decode to `false` — i.e. a real
    /// subscription, never a one-off.
    public static let defaultOneOff = false
    public static let defaultOutputOverride: String? = nil
    /// Default transcription language = auto-detect (empty sentinel). Was "de",
    /// which silently forced German once the per-show hint is wired; auto-detect
    /// is the safe default (the user can pin a language per show).
    public static let defaultLanguage = ""

    /// True when `code` means "let the model auto-detect" — tolerant of the
    /// historical sentinels used across the app ("", "auto", "Auto").
    public static func isAutoLanguage(_ code: String) -> Bool {
        let l = code.trimmingCharacters(in: .whitespaces).lowercased()
        return l.isEmpty || l == "auto"
    }

    /// The BCP-47 hint to pass the transcriber, or `nil` for auto-detect.
    public var languageHint: String? {
        Show.isAutoLanguage(language) ? nil : language
    }
    public static let defaultArtworkUrl = ""
    public static let defaultSource = "podcast"
    public static let defaultYoutubeTranscriptPref = ""
    public static let defaultSkipShorts = true
    public static let defaultIncludeVideos = true
    public static let defaultAutoVocab = false
    public static let defaultMinDurationSec = 0
    public static let defaultMaxDurationSec = 0
    public static let defaultNotify = true
    /// Default = "Always spoken word": never skip an episode as music. Existing
    /// shows (no key in YAML) decode to this, so they never lose an episode to a
    /// no-speech false positive.
    public static let defaultAssumeSpeech = true
    // v2-only
    public static let defaultIgReels = true
    public static let defaultIgPosts = true
    public static let defaultIgStories = true
    public static let defaultIgBackfillMode = "forward"
    public static let defaultIgBackfillN = 0
    // v2-only — unified backfill policy
    public static let defaultBackfillMode = "all"
    public static let defaultBackfillN = 10
    public static let defaultBackfillSince = ""
    public static let defaultMediaRetentionOverrideDays = -1
    // v2-only
    public static let defaultAuthor: String? = nil
    public static let defaultCreator: String? = nil
    public static let defaultCustomTitle: String? = nil
    /// Sentinel "added long ago" date for pre-existing shows (never "New").
    public static let defaultAddedAt = "2000-01-01"

    // MARK: - Memberwise init

    public init(
        slug: String,
        title: String,
        rss: String,
        whisperPrompt: String = defaultWhisperPrompt,
        enabled: Bool = defaultEnabled,
        oneOff: Bool = defaultOneOff,
        outputOverride: String? = defaultOutputOverride,
        language: String = defaultLanguage,
        artworkUrl: String = defaultArtworkUrl,
        source: String = defaultSource,
        youtubeTranscriptPref: String = defaultYoutubeTranscriptPref,
        skipShorts: Bool = defaultSkipShorts,
        includeVideos: Bool = defaultIncludeVideos,
        autoVocab: Bool = defaultAutoVocab,
        minDurationSec: Int = defaultMinDurationSec,
        maxDurationSec: Int = defaultMaxDurationSec,
        notify: Bool = defaultNotify,
        assumeSpeech: Bool = defaultAssumeSpeech,
        igReels: Bool = defaultIgReels,
        igPosts: Bool = defaultIgPosts,
        igStories: Bool = defaultIgStories,
        igBackfillMode: String = defaultIgBackfillMode,
        igBackfillN: Int = defaultIgBackfillN,
        backfillMode: String = defaultBackfillMode,
        backfillN: Int = defaultBackfillN,
        backfillSince: String = defaultBackfillSince,
        mediaRetentionOverrideDays: Int = defaultMediaRetentionOverrideDays,
        author: String? = defaultAuthor,
        creator: String? = defaultCreator,
        customTitle: String? = defaultCustomTitle,
        addedAt: String = defaultAddedAt
    ) {
        self.slug = slug
        self.title = title
        self.rss = rss
        self.whisperPrompt = whisperPrompt
        self.enabled = enabled
        self.oneOff = oneOff
        self.outputOverride = outputOverride
        self.language = language
        self.artworkUrl = artworkUrl
        self.source = source
        self.youtubeTranscriptPref = youtubeTranscriptPref
        self.skipShorts = skipShorts
        self.includeVideos = includeVideos
        self.autoVocab = autoVocab
        self.minDurationSec = minDurationSec
        self.maxDurationSec = maxDurationSec
        self.notify = notify
        self.assumeSpeech = assumeSpeech
        self.igReels = igReels
        self.igPosts = igPosts
        self.igStories = igStories
        self.igBackfillMode = igBackfillMode
        self.igBackfillN = igBackfillN
        self.backfillMode = backfillMode
        self.backfillN = backfillN
        self.backfillSince = backfillSince
        self.mediaRetentionOverrideDays = mediaRetentionOverrideDays
        self.author = author
        self.creator = creator
        self.customTitle = customTitle
        self.addedAt = addedAt
    }

    // MARK: - CodingKeys (camelCase ↔ snake_case YAML keys)

    enum CodingKeys: String, CodingKey {
        case slug
        case title
        case rss
        case whisperPrompt          = "whisper_prompt"
        case enabled
        case oneOff                 = "one_off"
        case outputOverride         = "output_override"
        case language
        case artworkUrl             = "artwork_url"
        case source
        case youtubeTranscriptPref  = "youtube_transcript_pref"
        case skipShorts             = "skip_shorts"
        case includeVideos          = "include_videos"
        case autoVocab              = "auto_vocab"
        case minDurationSec         = "min_duration_sec"
        case maxDurationSec         = "max_duration_sec"
        case notify
        case assumeSpeech           = "assume_speech"
        // v2-only
        case igReels                = "ig_reels"
        case igPosts                = "ig_posts"
        case igStories              = "ig_stories"
        case igBackfillMode         = "ig_backfill_mode"
        case igBackfillN            = "ig_backfill_n"
        // v2-only — unified backfill policy
        case backfillMode           = "backfill_mode"
        case backfillN              = "backfill_n"
        case backfillSince          = "backfill_since"
        case mediaRetentionOverrideDays = "media_retention_override_days"
        // v2-only
        case author
        case creator
        case customTitle            = "custom_title"
        case addedAt                = "added_at"
    }

    // MARK: - Custom decode (every missing key → Python-matching default)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Required — throw if absent
        slug  = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        rss   = try c.decode(String.self, forKey: .rss)

        // Defaulted Python fields
        whisperPrompt         = try c.decodeIfPresent(String.self,  forKey: .whisperPrompt)         ?? Self.defaultWhisperPrompt
        enabled               = try c.decodeIfPresent(Bool.self,    forKey: .enabled)               ?? Self.defaultEnabled
        // One-off flag — absent (existing shows / real subscriptions) → false.
        oneOff                = try c.decodeIfPresent(Bool.self,    forKey: .oneOff)                ?? Self.defaultOneOff
        outputOverride        = try c.decodeIfPresent(String.self,  forKey: .outputOverride)        ?? Self.defaultOutputOverride
        language              = try c.decodeIfPresent(String.self,  forKey: .language)              ?? Self.defaultLanguage
        artworkUrl            = try c.decodeIfPresent(String.self,  forKey: .artworkUrl)            ?? Self.defaultArtworkUrl
        source                = try c.decodeIfPresent(String.self,  forKey: .source)                ?? Self.defaultSource
        youtubeTranscriptPref = try c.decodeIfPresent(String.self,  forKey: .youtubeTranscriptPref) ?? Self.defaultYoutubeTranscriptPref
        skipShorts            = try c.decodeIfPresent(Bool.self,    forKey: .skipShorts)            ?? Self.defaultSkipShorts
        includeVideos         = try c.decodeIfPresent(Bool.self,    forKey: .includeVideos)         ?? Self.defaultIncludeVideos
        autoVocab             = try c.decodeIfPresent(Bool.self,    forKey: .autoVocab)             ?? Self.defaultAutoVocab
        minDurationSec        = try c.decodeIfPresent(Int.self,     forKey: .minDurationSec)        ?? Self.defaultMinDurationSec
        maxDurationSec        = try c.decodeIfPresent(Int.self,     forKey: .maxDurationSec)        ?? Self.defaultMaxDurationSec
        notify                = try c.decodeIfPresent(Bool.self,    forKey: .notify)                ?? Self.defaultNotify
        // Music-detection opt-out — absent (existing shows) → true ("Always
        // spoken word") so no episode is ever skipped as a no-speech false positive.
        assumeSpeech          = try c.decodeIfPresent(Bool.self,    forKey: .assumeSpeech)          ?? Self.defaultAssumeSpeech

        // v2-only additions
        igReels       = try c.decodeIfPresent(Bool.self,   forKey: .igReels)       ?? Self.defaultIgReels
        igPosts       = try c.decodeIfPresent(Bool.self,   forKey: .igPosts)       ?? Self.defaultIgPosts
        igStories     = try c.decodeIfPresent(Bool.self,   forKey: .igStories)     ?? Self.defaultIgStories
        igBackfillMode = try c.decodeIfPresent(String.self, forKey: .igBackfillMode) ?? Self.defaultIgBackfillMode
        igBackfillN   = try c.decodeIfPresent(Int.self,    forKey: .igBackfillN)   ?? Self.defaultIgBackfillN

        // Unified backfill policy — when the generic key is present, trust it
        // outright. When absent but a legacy `ig_backfill_mode` key WAS present
        // in the payload (old Instagram-only shows), seed the generic field
        // from the legacy value so existing IG subscriptions keep their scope
        // instead of silently reverting to "all". Otherwise default to "all".
        if let mode = try c.decodeIfPresent(String.self, forKey: .backfillMode) {
            backfillMode = mode
        } else if c.contains(.igBackfillMode), let legacy = try c.decodeIfPresent(String.self, forKey: .igBackfillMode) {
            switch legacy {
            case "full":    backfillMode = BackfillMode.all.rawValue
            case "last_n":  backfillMode = BackfillMode.lastN.rawValue
            case "forward": backfillMode = BackfillMode.onlyNew.rawValue
            default:        backfillMode = Self.defaultBackfillMode
            }
        } else {
            backfillMode = Self.defaultBackfillMode
        }
        if let n = try c.decodeIfPresent(Int.self, forKey: .backfillN) {
            backfillN = n
        } else if c.contains(.igBackfillMode) {
            // Legacy IG show — seed N from the legacy igBackfillN field.
            backfillN = igBackfillN
        } else {
            backfillN = Self.defaultBackfillN
        }
        backfillSince = try c.decodeIfPresent(String.self, forKey: .backfillSince) ?? Self.defaultBackfillSince
        mediaRetentionOverrideDays = try c.decodeIfPresent(Int.self, forKey: .mediaRetentionOverrideDays) ?? Self.defaultMediaRetentionOverrideDays

        // Author — nil/absent means not yet populated.
        let rawAuthor = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        author = rawAuthor.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rawAuthor

        // Explicit creator assignment — nil/absent means "use heuristic grouping".
        let rawCreator = try c.decodeIfPresent(String.self, forKey: .creator) ?? ""
        creator = rawCreator.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rawCreator

        // User-overridable display name — nil/absent means "use the feed title".
        let rawCustomTitle = try c.decodeIfPresent(String.self, forKey: .customTitle) ?? ""
        customTitle = rawCustomTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rawCustomTitle

        // Subscription date — absent means a pre-existing show → sentinel (never "New").
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt) ?? Self.defaultAddedAt
    }
}
