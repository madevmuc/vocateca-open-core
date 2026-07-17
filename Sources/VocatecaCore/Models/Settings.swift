import Foundation
import Yams

// MARK: - WebhookEntry

/// A single webhook definition.
///
/// Python model comment: `{events:[..], kind:"command"|"post", target:str, enabled:bool}`.
/// The shape is documented (not truly free-form) so we model it as a typed struct.
/// Fields default to safe values so a partially-written entry won't crash the decoder.
public struct WebhookEntry: Codable, Sendable, Equatable, Identifiable {
    public var events: [String]
    public var kind: String
    /// The destination URL (Python model calls this `target`).
    public var target: String
    public var enabled: Bool
    /// Stable id (v2). Auto-generated when absent in legacy configs.
    public var id: String
    /// HMAC-SHA256 signing secret (v2). Empty = unsigned.
    public var secret: String
    /// Payload format for this webhook: "raw" | (future formats added by
    /// later integration work). Defaults to "raw" so legacy entries (no
    /// `format` key) behave exactly as before.
    public var format: String

    public init(
        events: [String] = [],
        kind: String = "command",
        target: String = "",
        enabled: Bool = true,
        id: String = UUID().uuidString,
        secret: String = "",
        format: String = "raw"
    ) {
        self.events = events
        self.kind = kind
        self.target = target
        self.enabled = enabled
        self.id = id
        self.secret = secret
        self.format = format
    }

    enum CodingKeys: String, CodingKey { case events, kind, target, enabled, id, secret, format }

    // Custom decode so legacy entries (no id/secret/format) still parse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events  = try c.decodeIfPresent([String].self, forKey: .events)  ?? []
        kind    = try c.decodeIfPresent(String.self,   forKey: .kind)    ?? "command"
        target  = try c.decodeIfPresent(String.self,   forKey: .target)  ?? ""
        enabled = try c.decodeIfPresent(Bool.self,     forKey: .enabled) ?? true
        id      = try c.decodeIfPresent(String.self,   forKey: .id)      ?? UUID().uuidString
        secret  = try c.decodeIfPresent(String.self,   forKey: .secret)  ?? ""
        format  = try c.decodeIfPresent(String.self,   forKey: .format)  ?? "raw"
    }
}

/// What the app does when a YouTube link arrives from the Chrome extension via
/// `vocateca://youtube?url=…`. Stored as `youtube_link_action`.
public enum YouTubeLinkAction: String, Codable, Sendable, CaseIterable {
    /// Bring the app forward, jump to the Explorer tab, extract (default).
    case openAndExtract = "open_and_extract"
    /// Extract in the background without raising the app / stealing focus.
    case queueSilently = "queue_silently"
}

// MARK: - Settings

/// Global app settings.
///
/// Oracle-locked field-for-field port of `core/models.py :: Settings`.
/// Every field matches the Python model in name (as YAML key), type,
/// and **default value**.  Custom ``init(from:)`` ensures every missing key
/// falls back to the Python default — Yams/Codable does NOT do this automatically.
///
/// Validation replicated from Python:
/// - ``dailyCheckTime`` must match `^([01]\d|2[0-3]):[0-5]\d$` (HH:MM).
/// - ``_migrateLegacyLoadLevel`` replicates `_migrate_load_level`.
/// - ``backfillSetupCompleted`` replicates `backfill_setup_completed`.
public struct Settings: Codable, Sendable, Equatable {

    // MARK: Fields (Python model order preserved)

    public var outputRoot: String
    public var dailyCheckTime: String
    public var catchUpMissed: Bool
    public var updateCheckEnabled: Bool
    public var autoStartQueue: Bool
    public var autoStartDelaySeconds: Int
    public var notifyOnSuccess: Bool
    public var setupCompleted: Bool
    public var mp3RetentionDays: Int
    public var deleteMp3AfterTranscribe: Bool
    /// Auto-delete transcript files (.md + sibling .srt/.txt/.html) older than N
    /// days since `completed_at`. `0` = disabled / keep forever (safe default).
    public var transcriptRetentionDays: Int
    public var bandwidthLimitMbps: Int
    public var loadLevel: String
    public var obsidianVaultPath: String
    public var obsidianVaultName: String
    public var exportRoot: String
    /// Default transcript export format: "md" | "txt" | "srt" | "okf".
    public var defaultExportFormat: String
    /// Preferred app UI language: "system" | "en" | "de". Applied via the
    /// AppleLanguages UserDefaults override on the next launch.
    public var appLanguage: String
    public var whisperModel: String
    /// Transcription engine preference: "auto" | "whisper" | "qwen"
    /// (see ``TranscriptionEngine`` / ``EngineSelector``).
    public var transcriptionEngine: String
    /// Backup transcription engine (Package C): the engine the primary falls back
    /// to on a model load/download failure, or that language-routing uses for
    /// unsupported languages. Values as ``TranscriptionEngine``
    /// ("auto" | "whisper" | "qwen" | "parakeet"). Default "whisper" (the universal
    /// baseline). When it resolves to the same concrete engine as the primary it is
    /// treated as "no distinct fallback" (see ``EngineSelector/resolveFallback``).
    public var fallbackEngine: String
    /// Proper-noun correction level for new transcripts:
    /// "off" | "conservative" | "aggressive" (see
    /// ``TranscriptGlossaryCorrector/Level``). Rewrites metadata-known proper
    /// nouns after ASR on any engine. Default "conservative".
    public var properNounCorrection: String
    /// Qwen3-ASR model variant: "1.7B-8bit" | "1.7B-4bit" | "0.6B-8bit".
    public var qwenModel: String
    /// When using the Qwen3-ASR engine, run the forced aligner to produce real
    /// per-segment timestamps (proper .srt). Default on.
    public var qwenForcedAlign: Bool
    public var logRetentionDays: Int
    public var whisperFastMode: Bool
    public var rssConcurrency: Int
    public var downloadConcurrency: Int
    public var downloadConcurrencyPerHost: Int
    public var useEtagCache: Bool
    public var libraryScanCache: Bool
    public var notifyMode: String
    public var knowledgeHubRoot: String
    public var githubRepo: String
    public var saveSrt: Bool
    /// Also write a plain-text `.txt` sidecar next to the `.md`.
    public var saveTxt: Bool
    /// Also write a styled, self-contained `.html` sidecar next to the `.md`.
    public var saveHtml: Bool
    /// Also write an Open Knowledge Format `.okf.md` sidecar (Markdown +
    /// YAML frontmatter, minimally-opinionated) next to the `.md`.
    public var saveOkf: Bool
    /// Also write a WebVTT `.vtt` sidecar (timestamped subtitle cues) next to the `.md`.
    public var saveVtt: Bool
    /// Also write an RFC-4180 CSV `.csv` sidecar (`start,end,speaker,text`, one
    /// row per segment) next to the `.md`. The `speaker` column is only
    /// populated when diarization produced a result for that segment.
    public var saveCsv: Bool
    public var sourcesPodcasts: Bool
    public var sourcesYoutube: Bool
    public var ytdlpLastSelfUpdateAt: String
    public var youtubeDefaultTranscriptSource: String
    public var youtubeDefaultLanguage: String
    public var youtubeSkipShortsDefault: Bool
    public var showLogDock: Bool
    /// Keep the app resident in the menu bar + register a login item so the Pro
    /// daemon's scheduled runs fire even with no window open. Default ON.
    public var runInBackground: Bool
    /// Governs Sparkle's `SPUUpdater.automaticallyChecksForUpdates`, set
    /// programmatically at launch so Sparkle never shows its own surprise
    /// first-launch "check for updates automatically?" permission prompt —
    /// the app makes an INFORMED default choice instead (ON) and surfaces it
    /// as an ordinary Settings toggle. Default `true`.
    public var autoCheckForUpdates: Bool
    /// True once the FirstRunWizard has finished. Gates `AppShell.applyBackgroundMode()`
    /// so the macOS login item is never silently registered before onboarding has
    /// shown the user the autostart tile. Default OFF (fresh installs must complete
    /// onboarding first); the decode path backfills `true` for upgrading installs
    /// that already accepted the disclaimer, so existing users don't lose background
    /// mode / login-item management on update.
    public var hasCompletedFirstRun: Bool
    /// While resident in the background with no window open, hide the Dock icon
    /// (menu-bar-only). Default OFF (Dock icon shown).
    public var hideDockIconInBackground: Bool
    public var connectivityMonitorEnabled: Bool
    public var autoResumeFailedWindowHours: Int
    public var watchFolderEnabled: Bool
    public var watchFolderRoot: String
    public var watchFolderPost: String
    public var localMaxDurationHours: Int
    // roadmap 0.2 additions
    public var eventRetentionDays: Int
    public var notifyEvents: [String: Bool]
    public var notifyQuietHoursEnabled: Bool
    public var notifyQuietHoursStart: String
    public var notifyQuietHoursEnd: String
    public var webhooksEnabled: Bool
    public var webhooks: [WebhookEntry]
    /// Notion integration: master enable switch. The Notion API token itself
    /// is NOT stored here — it lives in the Keychain via `IntegrationSecrets`.
    public var notionEnabled: Bool
    /// When true, newly-transcribed episodes are automatically pushed to Notion.
    public var notionAutoPush: Bool
    /// Target Notion database id for pushed episode pages.
    public var notionDatabaseId: String
    public var queueOrder: String
    /// How OLD episodes get drained when a backfill batch is promoted to the
    /// queue: `"newest_first"` (default — most-relevant-first) | `"oldest_first"`
    /// (chronological). Governs ONLY `BackfillCampaignAdvancer`'s priority-0
    /// top-up batches (see `Episode.backfillSeq`) — the live, non-backfill
    /// queue drain always stays governed by `queueOrder`, unaffected by this
    /// field. Stored as `backfill_order`. Oracle-excluded — no Python model
    /// counterpart (v2-only, StateStore §D).
    public var backfillOrder: String
    public var defaultMinDurationSec: Int
    public var defaultMaxDurationSec: Int
    public var captionFallbackMode: String
    public var confidenceMarkingEnabled: Bool
    public var confidenceThreshold: Double
    public var processingWindowsEnabled: Bool
    public var processingWindows: [String]
    public var pauseOnBattery: Bool
    public var batteryLoadLevel: String
    public var pauseQueueOnBattery: Bool
    /// Battery/power policy for the transcription queue (`BatteryPolicy` raw value).
    /// Supersedes the three fields above (kept decodable for back-compat/migration).
    public var batteryPolicy: String
    /// What happens to the app MODE (Background/Power) when the Mac switches to
    /// battery: `"keep"` (leave the mode as-is) or `"to_background"` (drop to
    /// Background to save power, restoring the previous mode when plugged back in).
    public var batteryModeBehavior: String
    public var transcribeConcurrency: Int
    public var whisperMetalEnabled: Bool
    public var whisperModelAutopick: Bool
    public var diarizationEnabled: Bool
    public var diarizationModelDir: String
    public var diskGuardEnabled: Bool
    public var diskGuardMinFreeGb: Int
    /// Free-GB threshold below which the app-wide low-disk HUD appears (a
    /// floating bar that blocks nothing). Stored as `disk_warn_hud_gb`.
    /// Constrained against the two neighbours by ``DiskThresholds/resolve(hudGb:modalGb:pauseGb:)``.
    public var diskWarnHudGb: Int
    /// Free-GB threshold below which the low-disk warning escalates to a modal
    /// dialog. Stored as `disk_warn_modal_gb`. Always `<= diskWarnHudGb`.
    public var diskWarnModalGb: Int
    /// Global media-folder size cap: when enabled, the maintenance pass evicts
    /// the oldest downloaded mp3s (by file mtime) until the media dir is back
    /// under this many GB. Decimal GB (×1e9), matching `DiskGuard`. Runs AFTER
    /// the age-based retention pass. Stored as `media_storage_cap_gb`.
    public var mediaStorageCapGb: Int
    /// Master enable switch for the storage cap above. Stored as
    /// `media_storage_cap_enabled`.
    public var mediaStorageCapEnabled: Bool

    // v2-only additions (Instagram sources)
    public var sourcesInstagram: Bool
    /// Kept for backward-compat with existing settings.yaml files; no longer the
    /// primary UI control — use `instagramFetchIntervalMinutes` instead.
    public var instagramRate: String
    /// How often vocateca refreshes Instagram sources (polls for both new and
    /// older content). Stored as `instagram_fetch_interval_minutes`. Default 360 (= 6 h).
    public var instagramFetchIntervalMinutes: Int
    public var igDefaultReels: Bool
    public var igDefaultPosts: Bool
    public var igDefaultStories: Bool
    public var instagramStoriesIntervalMinutes: Int
    public var proEntitlementStatus: String
    public var proEntitlementCachedAt: String
    public var lastUpsellShownAt: String
    public var disclaimerAcceptedAt: String
    public var disclaimerVersion: String
    public var dailyCheckEnabled: Bool
    /// v2-only. How often to show the upsell prompt. Values: "daily" | "weekly". Default "daily".
    /// Never shown to Pro subscribers. Minimum enforced by ``UpsellThrottle``: once per week.
    public var upsellFrequency: String

    // MARK: - Welle D1 additions

    /// Which media types should trigger notifications. Values: "podcast", "youtube", "instagram".
    /// An empty array means notifications are off for all types.
    /// Stored as `notify_media_types`. Default: all three types enabled.
    /// Oracle-excluded — no Python model counterpart.
    public var notifyMediaTypes: [String]

    /// Default for new YouTube channels: include standard videos. Default `true`.
    /// Stored as `youtube_include_videos_default`.
    /// Oracle-excluded — no Python model counterpart.
    public var youtubeIncludeVideosDefault: Bool

    /// v2-only. List of keywords/phrases to watch for in newly-transcribed episodes.
    /// When a keyword is found a `keyword.match` event is emitted via `EventBus`.
    /// Stored as `keyword_watch` in settings.yaml. Default: empty array.
    /// Oracle-excluded — no Python model counterpart.
    public var keywordWatch: [WatchTerm]

    /// v2-only. Per-table column layout (visibility / width / order + active sort),
    /// keyed by table id ("shows" / "library" / "failed" / "creators"). Portable via
    /// settings.yaml as `table_layouts`. Default empty — each table then falls back to
    /// its code-defined column defaults (reconciled via `TableLayout.merge`).
    public var tableLayouts: [String: TableLayout]

    // MARK: - Mode & performance settings (v2-only, oracle-excluded)

    /// The Power mode auto-revert policy.
    /// Values: "after24h" | "untilQueueDone" | "customTime". Default "after24h".
    /// Stored as `power_revert_policy` in settings.yaml.
    /// Kept for backward-compat YAML decode; no longer surfaced in UI (replaced by
    /// `powerRevertAfterQueue`).
    public var powerRevertPolicy: String

    /// The default startup mode.
    /// Values: "background" | "power". Default "background".
    /// Stored as `default_startup_mode` in settings.yaml.
    /// Kept for backward-compat YAML decode; no longer surfaced in UI (live mode is
    /// now controlled by AppModeController directly).
    public var defaultStartupMode: String

    /// When `true` (the default), Power mode automatically reverts to Background
    /// when the current queue finishes processing.  When `false`, Power stays until
    /// the user changes it manually.
    /// Stored as `power_revert_after_queue` in settings.yaml.
    /// Oracle-excluded — no Python model counterpart.
    public var powerRevertAfterQueue: Bool

    // MARK: - Welle N (Pro daily summary)

    /// Pro feature: emit a single "daily summary" notification at the end of each
    /// auto-download + transcribe run, listing how many episodes were processed.
    /// Default `true`. Stored as `daily_summary` in settings.yaml.
    /// Oracle-excluded — no Python model counterpart.
    public var dailySummary: Bool

    // MARK: - Welle V (startup tab)

    /// When `true`, vocateca re-opens the sidebar tab that was active when the
    /// app was last closed. When `false`, opens `startupTab` instead.
    /// Stored as `open_on_last_used_tab`. Default `true`.
    /// Oracle-excluded — no Python model counterpart.
    public var openOnLastUsedTab: Bool

    /// The sidebar tab to open on launch when `openOnLastUsedTab` is `false`.
    /// Value is a `SidebarItem.rawValue` string (e.g. "Shows").
    /// Stored as `startup_tab`. Default `"Shows"`.
    /// Oracle-excluded — no Python model counterpart.
    public var startupTab: String

    // MARK: - Welle system-notifications (per-kind forward-to-system map)

    /// Per-kind override map for forwarding in-app notifications to the macOS
    /// Notification Center.  Key = ``NotifKindKey`` raw-value string
    /// (e.g. `"failure"`, `"dailySummary"`); value = `true` (forward) or
    /// `false` (suppress).  When a kind has no entry,
    /// `SystemNotificationPolicy.defaultForward(for:isPro:)` applies
    /// (default: false for all kinds except `dailySummary` for Pro users).
    /// Stored as `forward_to_system`. Default: empty map.
    /// Oracle-excluded — no Python model counterpart.
    public var forwardToSystem: [String: Bool]

    // MARK: - Quick-nav shortcut hints

    /// When `true`, shows the assigned ⌘1–⌘N quick-nav shortcut in button
    /// tooltips throughout the app. The quick-nav order itself lives in
    /// `UserDefaults` key `"vocateca.quickNavOrder"`, not in this model.
    /// Stored as `show_shortcut_hints`. Default `true`.
    /// Oracle-excluded — no Python model counterpart.
    public var showShortcutHints: Bool

    // MARK: - YouTube video preview
    //
    // (`youtube_explorer_enabled` is gone: it gated a sidebar tab that no longer
    //  exists — a video with its transcript is a state of the Add tab now, and a
    //  switch for it could only lie. Old settings.yaml files still carrying the
    //  key decode fine; every field here is `decodeIfPresent`, so an unknown one
    //  is simply ignored.)

    /// Default format used by the video preview's "Copy" split-button.
    /// Values: any `TranscriptFormat` id ("md" | "txt" | "srt" | "html" | "okf"
    /// | "vtt" | "csv"). Default `"txt"`. Stored as `youtube_copy_format`.
    /// Oracle-excluded — no Python model counterpart.
    public var youtubeCopyFormat: String

    /// What happens when a YouTube link is sent from the browser extension.
    /// Default `.openAndExtract`. Stored as `youtube_link_action`.
    /// Oracle-excluded — no Python model counterpart.
    public var youtubeLinkAction: YouTubeLinkAction

    // MARK: - Update UX (Task A1: custom Sparkle auto-update)

    /// Update check interval: `false` (default) = daily, `true` = weekly. Maps
    /// to `SPUUpdater.updateCheckInterval` via
    /// `UpdaterSettingsBridge.updateIntervalSeconds(weekly:)` (86400 / 604800
    /// seconds). Stored as `update_interval_weekly`.
    /// Oracle-excluded — no Python model counterpart.
    public var updateIntervalWeekly: Bool

    /// Auto-install found updates silently (maps to
    /// `SPUUpdater.automaticallyDownloadsUpdates`). Default `true`. When
    /// `false`, the custom update-available popup is shown instead (see
    /// `UpdatePolicy`, Task A2). Stored as `auto_install_updates`.
    /// Oracle-excluded — no Python model counterpart.
    public var autoInstallUpdates: Bool

    /// "Remind me later" snooze timestamp for the custom update-available
    /// popup (auto-install OFF path): while `Date() < updateRemindAfter`, the
    /// popup is suppressed for the same found version. `nil` = no active
    /// snooze. Stored as `update_remind_after`.
    /// Oracle-excluded — no Python model counterpart.
    public var updateRemindAfter: Date?

    /// Version the user chose "Skip this version" for (custom update-available
    /// popup, Task A3's `VocatecaUpdaterDriver`): while `foundVersion ==
    /// skippedUpdateVersion`, `UpdatePolicy.decide` suppresses the popup for
    /// that exact version — a NEWER version does not match and re-shows.
    /// `nil` = no active skip. Stored as `skipped_update_version`.
    /// Oracle-excluded — no Python model counterpart.
    public var skippedUpdateVersion: String?

    // MARK: - Defaults

    public static let defaultOutputRoot                    = "~/Documents/transcripts - vocateca"
    public static let defaultDailyCheckTime               = "09:00"
    public static let defaultCatchUpMissed                = true
    public static let defaultUpdateCheckEnabled           = true
    public static let defaultAutoStartQueue               = true
    public static let defaultAutoStartDelaySeconds        = 5
    public static let defaultNotifyOnSuccess              = true
    public static let defaultSetupCompleted               = false
    public static let defaultMp3RetentionDays             = 7
    /// Changed from `true` → `false` so the 7-day age-out above actually takes
    /// effect for fresh installs (a `true` default deleted media immediately on
    /// transcribe, before `mp3RetentionDays` ever mattered). Existing users'
    /// persisted settings are unaffected — this only changes the default for
    /// missing/fresh installs.
    public static let defaultDeleteMp3AfterTranscribe     = false
    public static let defaultTranscriptRetentionDays      = 0
    public static let defaultBandwidthLimitMbps           = 0
    public static let defaultLoadLevel                    = "balanced"
    public static let defaultObsidianVaultPath            = ""
    public static let defaultObsidianVaultName            = "knowledge-hub"
    public static let defaultExportRoot                   = "~/Documents/transcripts - vocateca"
    public static let defaultDefaultExportFormat          = "md"
    public static let defaultAppLanguage                  = "system"
    public static let defaultWhisperModel                 = "large-v3-turbo"
    public static let defaultLogRetentionDays             = 90
    public static let defaultWhisperFastMode              = false
    public static let defaultRssConcurrency               = 8
    public static let defaultDownloadConcurrency          = 4
    public static let defaultDownloadConcurrencyPerHost   = 2
    public static let defaultUseEtagCache                 = true
    public static let defaultLibraryScanCache             = true
    public static let defaultNotifyMode                   = "per_episode"
    public static let defaultKnowledgeHubRoot             = ""
    public static let defaultGithubRepo                   = "madevmuc/vocateca"
    public static let defaultSaveSrt                      = true
    public static let defaultSaveTxt                      = false
    public static let defaultSaveHtml                     = false
    public static let defaultSaveOkf                      = false
    public static let defaultSaveVtt                      = false
    public static let defaultSaveCsv                      = false
    public static let defaultSourcesPodcasts              = true
    public static let defaultSourcesYoutube               = true
    public static let defaultYtdlpLastSelfUpdateAt        = ""
    public static let defaultYoutubeDefaultTranscriptSource = "captions"
    public static let defaultYoutubeDefaultLanguage       = "de"
    public static let defaultYoutubeSkipShortsDefault     = true
    public static let defaultShowLogDock                  = false
    public static let defaultRunInBackground              = true
    public static let defaultAutoCheckForUpdates          = true
    public static let defaultHasCompletedFirstRun         = false
    public static let defaultHideDockIconInBackground     = false
    public static let defaultConnectivityMonitorEnabled   = true
    public static let defaultAutoResumeFailedWindowHours  = 24
    public static let defaultWatchFolderEnabled           = false
    public static let defaultWatchFolderRoot              = "~/Vocateca/to-be-transcribed"
    public static let defaultWatchFolderPost              = "keep"
    public static let defaultLocalMaxDurationHours        = 4
    // roadmap 0.2
    public static let defaultEventRetentionDays           = 90
    public static var defaultNotifyEvents: [String: Bool] {
        ["episode.transcribed": true, "run.finished": true, "episode.failed": true]
    }
    public static let defaultNotifyQuietHoursEnabled      = true
    public static let defaultNotifyQuietHoursStart        = "22:00"
    public static let defaultNotifyQuietHoursEnd          = "08:00"
    public static let defaultWebhooksEnabled              = false
    public static let defaultWebhooks: [WebhookEntry]     = []
    public static let defaultNotionEnabled                = false
    public static let defaultNotionAutoPush               = false
    public static let defaultNotionDatabaseId             = ""
    public static let defaultQueueOrder                   = "oldest_first"
    public static let defaultBackfillOrder                = "newest_first"
    public static let defaultDefaultMinDurationSec        = 0
    public static let defaultDefaultMaxDurationSec        = 0
    public static let defaultCaptionFallbackMode          = "manual_whisper"
    public static let defaultTranscriptionEngine          = "auto"
    public static let defaultFallbackEngine               = "whisper"
    public static let defaultProperNounCorrection         = "conservative"
    public static let defaultQwenModel                    = "1.7B-8bit"
    public static let defaultQwenForcedAlign              = true
    public static let defaultConfidenceMarkingEnabled     = true
    public static let defaultConfidenceThreshold: Double  = 0.5
    public static let defaultProcessingWindowsEnabled     = false
    public static let defaultProcessingWindows: [String]  = []
    public static let defaultPauseOnBattery               = false
    public static let defaultBatteryLoadLevel             = "quiet"
    public static let defaultPauseQueueOnBattery          = false
    public static let defaultBatteryPolicy                = BatteryPolicy.default.rawValue
    public static let defaultBatteryModeBehavior          = "to_background"
    public static let defaultTranscribeConcurrency        = 1
    public static let defaultWhisperMetalEnabled          = true
    public static let defaultWhisperModelAutopick         = false
    public static let defaultDiarizationEnabled           = true
    public static let defaultDiarizationModelDir          = ""
    public static let defaultDiskGuardEnabled             = true
    public static let defaultDiskGuardMinFreeGb           = 5
    /// Matches `defaultDiskGuardMinFreeGb`: the HUD is meant to explain the pause
    /// at the moment work actually stops, not before it.
    public static let defaultDiskWarnHudGb                = 5
    /// Well below the HUD, so the escalation has room to be an escalation.
    public static let defaultDiskWarnModalGb              = 2
    public static let defaultMediaStorageCapGb            = 10
    public static let defaultMediaStorageCapEnabled       = true
    // v2-only
    public static let defaultDailyCheckEnabled            = true
    public static let defaultSourcesInstagram             = false
    public static let defaultInstagramRate                = "normal"
    /// Default fetch interval for Instagram sources: 6 hours = 360 minutes.
    public static let defaultInstagramFetchIntervalMinutes = 360
    public static let defaultIgDefaultReels               = true
    public static let defaultIgDefaultPosts               = true
    public static let defaultIgDefaultStories             = true
    public static let defaultInstagramStoriesIntervalMinutes = 360
    public static let defaultProEntitlementStatus         = "unknown"
    public static let defaultProEntitlementCachedAt       = ""
    public static let defaultLastUpsellShownAt            = ""
    public static let defaultDisclaimerAcceptedAt         = ""
    public static let defaultDisclaimerVersion            = ""
    // v2-only (oracle-excluded — no Python counterpart)
    public static let defaultUpsellFrequency              = "daily"
    public static let defaultKeywordWatch: [WatchTerm]    = []
    public static let defaultTableLayouts: [String: TableLayout] = [:]
    // Welle D1 additions (oracle-excluded)
    public static var defaultNotifyMediaTypes: [String]   { ["podcast", "youtube", "instagram"] }
    public static let defaultYoutubeIncludeVideosDefault  = true
    // v2-only, mode & performance (oracle-excluded)
    public static let defaultPowerRevertPolicy            = "after24h"
    public static let defaultDefaultStartupMode           = "background"
    public static let defaultPowerRevertAfterQueue        = true
    // v2-only, Welle N (oracle-excluded)
    public static let defaultDailySummary                 = true
    // v2-only, Welle V (oracle-excluded)
    public static let defaultOpenOnLastUsedTab            = true
    public static let defaultStartupTab                   = "Shows"
    // v2-only, Welle system-notifications (oracle-excluded)
    public static var defaultForwardToSystem: [String: Bool] { [:] }
    // v2-only, quick-nav shortcut hints (oracle-excluded)
    public static let defaultShowShortcutHints            = true
    // v2-only, Update UX (Task A1, oracle-excluded)
    public static let defaultUpdateIntervalWeekly         = false
    public static let defaultAutoInstallUpdates           = true
    public static let defaultUpdateRemindAfter: Date?     = nil
    public static let defaultSkippedUpdateVersion: String? = nil

    // v2-only, Welle YT-Explorer (oracle-excluded)
    // Default ON: the YouTube Explorer is the natural surface for a link sent
    // from the Chrome extension (video + timestamped transcript), so it ships
    // enabled. A fresh intake also force-enables it (see AppShell's intake
    // observer) in case a user turned it off.
    public static let defaultYoutubeCopyFormat            = "txt"
    public static let defaultYoutubeLinkAction           = YouTubeLinkAction.openAndExtract

    // MARK: - Memberwise init

    public init(
        outputRoot: String                    = defaultOutputRoot,
        dailyCheckTime: String                = defaultDailyCheckTime,
        catchUpMissed: Bool                   = defaultCatchUpMissed,
        updateCheckEnabled: Bool              = defaultUpdateCheckEnabled,
        autoStartQueue: Bool                  = defaultAutoStartQueue,
        autoStartDelaySeconds: Int            = defaultAutoStartDelaySeconds,
        notifyOnSuccess: Bool                 = defaultNotifyOnSuccess,
        setupCompleted: Bool                  = defaultSetupCompleted,
        mp3RetentionDays: Int                 = defaultMp3RetentionDays,
        deleteMp3AfterTranscribe: Bool        = defaultDeleteMp3AfterTranscribe,
        transcriptRetentionDays: Int          = defaultTranscriptRetentionDays,
        bandwidthLimitMbps: Int               = defaultBandwidthLimitMbps,
        loadLevel: String                     = defaultLoadLevel,
        obsidianVaultPath: String             = defaultObsidianVaultPath,
        obsidianVaultName: String             = defaultObsidianVaultName,
        exportRoot: String                    = defaultExportRoot,
        defaultExportFormat: String           = defaultDefaultExportFormat,
        appLanguage: String                   = defaultAppLanguage,
        whisperModel: String                  = defaultWhisperModel,
        transcriptionEngine: String           = defaultTranscriptionEngine,
        fallbackEngine: String                = defaultFallbackEngine,
        properNounCorrection: String          = defaultProperNounCorrection,
        qwenModel: String                     = defaultQwenModel,
        qwenForcedAlign: Bool                 = defaultQwenForcedAlign,
        logRetentionDays: Int                 = defaultLogRetentionDays,
        whisperFastMode: Bool                 = defaultWhisperFastMode,
        rssConcurrency: Int                   = defaultRssConcurrency,
        downloadConcurrency: Int              = defaultDownloadConcurrency,
        downloadConcurrencyPerHost: Int       = defaultDownloadConcurrencyPerHost,
        useEtagCache: Bool                    = defaultUseEtagCache,
        libraryScanCache: Bool                = defaultLibraryScanCache,
        notifyMode: String                    = defaultNotifyMode,
        knowledgeHubRoot: String              = defaultKnowledgeHubRoot,
        githubRepo: String                    = defaultGithubRepo,
        saveSrt: Bool                         = defaultSaveSrt,
        saveTxt: Bool                         = defaultSaveTxt,
        saveHtml: Bool                        = defaultSaveHtml,
        saveOkf: Bool                         = defaultSaveOkf,
        saveVtt: Bool                         = defaultSaveVtt,
        saveCsv: Bool                         = defaultSaveCsv,
        sourcesPodcasts: Bool                 = defaultSourcesPodcasts,
        sourcesYoutube: Bool                  = defaultSourcesYoutube,
        ytdlpLastSelfUpdateAt: String         = defaultYtdlpLastSelfUpdateAt,
        youtubeDefaultTranscriptSource: String = defaultYoutubeDefaultTranscriptSource,
        youtubeDefaultLanguage: String        = defaultYoutubeDefaultLanguage,
        youtubeSkipShortsDefault: Bool        = defaultYoutubeSkipShortsDefault,
        showLogDock: Bool                     = defaultShowLogDock,
        runInBackground: Bool                 = defaultRunInBackground,
        autoCheckForUpdates: Bool             = defaultAutoCheckForUpdates,
        hasCompletedFirstRun: Bool            = defaultHasCompletedFirstRun,
        hideDockIconInBackground: Bool        = defaultHideDockIconInBackground,
        connectivityMonitorEnabled: Bool      = defaultConnectivityMonitorEnabled,
        autoResumeFailedWindowHours: Int      = defaultAutoResumeFailedWindowHours,
        watchFolderEnabled: Bool              = defaultWatchFolderEnabled,
        watchFolderRoot: String               = defaultWatchFolderRoot,
        watchFolderPost: String               = defaultWatchFolderPost,
        localMaxDurationHours: Int            = defaultLocalMaxDurationHours,
        eventRetentionDays: Int               = defaultEventRetentionDays,
        notifyEvents: [String: Bool]          = defaultNotifyEvents,
        notifyQuietHoursEnabled: Bool         = defaultNotifyQuietHoursEnabled,
        notifyQuietHoursStart: String         = defaultNotifyQuietHoursStart,
        notifyQuietHoursEnd: String           = defaultNotifyQuietHoursEnd,
        webhooksEnabled: Bool                 = defaultWebhooksEnabled,
        webhooks: [WebhookEntry]              = defaultWebhooks,
        notionEnabled: Bool                   = defaultNotionEnabled,
        notionAutoPush: Bool                  = defaultNotionAutoPush,
        notionDatabaseId: String              = defaultNotionDatabaseId,
        queueOrder: String                    = defaultQueueOrder,
        backfillOrder: String                 = defaultBackfillOrder,
        defaultMinDurationSec: Int            = defaultDefaultMinDurationSec,
        defaultMaxDurationSec: Int            = defaultDefaultMaxDurationSec,
        captionFallbackMode: String           = defaultCaptionFallbackMode,
        confidenceMarkingEnabled: Bool        = defaultConfidenceMarkingEnabled,
        confidenceThreshold: Double           = defaultConfidenceThreshold,
        processingWindowsEnabled: Bool        = defaultProcessingWindowsEnabled,
        processingWindows: [String]           = defaultProcessingWindows,
        pauseOnBattery: Bool                  = defaultPauseOnBattery,
        batteryLoadLevel: String              = defaultBatteryLoadLevel,
        pauseQueueOnBattery: Bool             = defaultPauseQueueOnBattery,
        batteryPolicy: String                 = defaultBatteryPolicy,
        batteryModeBehavior: String           = defaultBatteryModeBehavior,
        transcribeConcurrency: Int            = defaultTranscribeConcurrency,
        whisperMetalEnabled: Bool             = defaultWhisperMetalEnabled,
        whisperModelAutopick: Bool            = defaultWhisperModelAutopick,
        diarizationEnabled: Bool              = defaultDiarizationEnabled,
        diarizationModelDir: String           = defaultDiarizationModelDir,
        diskGuardEnabled: Bool                = defaultDiskGuardEnabled,
        diskGuardMinFreeGb: Int               = defaultDiskGuardMinFreeGb,
        diskWarnHudGb: Int                    = defaultDiskWarnHudGb,
        diskWarnModalGb: Int                  = defaultDiskWarnModalGb,
        mediaStorageCapGb: Int                = defaultMediaStorageCapGb,
        mediaStorageCapEnabled: Bool          = defaultMediaStorageCapEnabled,
        sourcesInstagram: Bool                = defaultSourcesInstagram,
        instagramRate: String                 = defaultInstagramRate,
        instagramFetchIntervalMinutes: Int    = defaultInstagramFetchIntervalMinutes,
        igDefaultReels: Bool                  = defaultIgDefaultReels,
        igDefaultPosts: Bool                  = defaultIgDefaultPosts,
        igDefaultStories: Bool                = defaultIgDefaultStories,
        instagramStoriesIntervalMinutes: Int  = defaultInstagramStoriesIntervalMinutes,
        proEntitlementStatus: String          = defaultProEntitlementStatus,
        proEntitlementCachedAt: String        = defaultProEntitlementCachedAt,
        lastUpsellShownAt: String             = defaultLastUpsellShownAt,
        disclaimerAcceptedAt: String          = defaultDisclaimerAcceptedAt,
        disclaimerVersion: String             = defaultDisclaimerVersion,
        dailyCheckEnabled: Bool               = defaultDailyCheckEnabled,
        upsellFrequency: String               = defaultUpsellFrequency,
        notifyMediaTypes: [String]            = defaultNotifyMediaTypes,
        youtubeIncludeVideosDefault: Bool     = defaultYoutubeIncludeVideosDefault,
        keywordWatch: [WatchTerm]             = defaultKeywordWatch,
        tableLayouts: [String: TableLayout]   = defaultTableLayouts,
        powerRevertPolicy: String             = defaultPowerRevertPolicy,
        defaultStartupMode: String            = defaultDefaultStartupMode,
        powerRevertAfterQueue: Bool           = defaultPowerRevertAfterQueue,
        dailySummary: Bool                    = defaultDailySummary,
        openOnLastUsedTab: Bool               = defaultOpenOnLastUsedTab,
        startupTab: String                    = defaultStartupTab,
        forwardToSystem: [String: Bool]       = defaultForwardToSystem,
        showShortcutHints: Bool               = defaultShowShortcutHints,
        updateIntervalWeekly: Bool             = defaultUpdateIntervalWeekly,
        autoInstallUpdates: Bool               = defaultAutoInstallUpdates,
        updateRemindAfter: Date?               = defaultUpdateRemindAfter,
        skippedUpdateVersion: String?          = defaultSkippedUpdateVersion,
        youtubeCopyFormat: String             = defaultYoutubeCopyFormat,
        youtubeLinkAction: YouTubeLinkAction  = defaultYoutubeLinkAction
    ) {
        self.outputRoot                      = outputRoot
        self.dailyCheckTime                  = dailyCheckTime
        self.catchUpMissed                   = catchUpMissed
        self.updateCheckEnabled              = updateCheckEnabled
        self.autoStartQueue                  = autoStartQueue
        self.autoStartDelaySeconds           = autoStartDelaySeconds
        self.notifyOnSuccess                 = notifyOnSuccess
        self.setupCompleted                  = setupCompleted
        self.mp3RetentionDays                = mp3RetentionDays
        self.deleteMp3AfterTranscribe        = deleteMp3AfterTranscribe
        self.transcriptRetentionDays         = transcriptRetentionDays
        self.bandwidthLimitMbps              = bandwidthLimitMbps
        self.loadLevel                       = loadLevel
        self.obsidianVaultPath               = obsidianVaultPath
        self.obsidianVaultName               = obsidianVaultName
        self.exportRoot                      = exportRoot
        self.defaultExportFormat             = defaultExportFormat
        self.appLanguage                     = appLanguage
        self.whisperModel                    = whisperModel
        self.transcriptionEngine             = transcriptionEngine
        self.fallbackEngine                  = fallbackEngine
        self.properNounCorrection            = properNounCorrection
        self.qwenModel                       = qwenModel
        self.qwenForcedAlign                 = qwenForcedAlign
        self.logRetentionDays                = logRetentionDays
        self.whisperFastMode                 = whisperFastMode
        self.rssConcurrency                  = rssConcurrency
        self.downloadConcurrency             = downloadConcurrency
        self.downloadConcurrencyPerHost      = downloadConcurrencyPerHost
        self.useEtagCache                    = useEtagCache
        self.libraryScanCache                = libraryScanCache
        self.notifyMode                      = notifyMode
        self.knowledgeHubRoot                = knowledgeHubRoot
        self.githubRepo                      = githubRepo
        self.saveSrt                         = saveSrt
        self.saveTxt                         = saveTxt
        self.saveHtml                        = saveHtml
        self.saveOkf                         = saveOkf
        self.saveVtt                         = saveVtt
        self.saveCsv                         = saveCsv
        self.sourcesPodcasts                 = sourcesPodcasts
        self.sourcesYoutube                  = sourcesYoutube
        self.ytdlpLastSelfUpdateAt           = ytdlpLastSelfUpdateAt
        self.youtubeDefaultTranscriptSource  = youtubeDefaultTranscriptSource
        self.youtubeDefaultLanguage          = youtubeDefaultLanguage
        self.youtubeSkipShortsDefault        = youtubeSkipShortsDefault
        self.showLogDock                     = showLogDock
        self.runInBackground              = runInBackground
        self.autoCheckForUpdates          = autoCheckForUpdates
        self.hasCompletedFirstRun         = hasCompletedFirstRun
        self.hideDockIconInBackground     = hideDockIconInBackground
        self.connectivityMonitorEnabled      = connectivityMonitorEnabled
        self.autoResumeFailedWindowHours     = autoResumeFailedWindowHours
        self.watchFolderEnabled              = watchFolderEnabled
        self.watchFolderRoot                 = watchFolderRoot
        self.watchFolderPost                 = watchFolderPost
        self.localMaxDurationHours           = localMaxDurationHours
        self.eventRetentionDays              = eventRetentionDays
        self.notifyEvents                    = notifyEvents
        self.notifyQuietHoursEnabled         = notifyQuietHoursEnabled
        self.notifyQuietHoursStart           = notifyQuietHoursStart
        self.notifyQuietHoursEnd             = notifyQuietHoursEnd
        self.webhooksEnabled                 = webhooksEnabled
        self.webhooks                        = webhooks
        self.notionEnabled                   = notionEnabled
        self.notionAutoPush                  = notionAutoPush
        self.notionDatabaseId                = notionDatabaseId
        self.queueOrder                      = queueOrder
        self.backfillOrder                   = backfillOrder
        self.defaultMinDurationSec           = defaultMinDurationSec
        self.defaultMaxDurationSec           = defaultMaxDurationSec
        self.captionFallbackMode             = captionFallbackMode
        self.confidenceMarkingEnabled        = confidenceMarkingEnabled
        self.confidenceThreshold             = confidenceThreshold
        self.processingWindowsEnabled        = processingWindowsEnabled
        self.processingWindows               = processingWindows
        self.pauseOnBattery                  = pauseOnBattery
        self.batteryLoadLevel                = batteryLoadLevel
        self.pauseQueueOnBattery             = pauseQueueOnBattery
        self.batteryPolicy                   = batteryPolicy
        self.batteryModeBehavior             = batteryModeBehavior
        self.transcribeConcurrency           = transcribeConcurrency
        self.whisperMetalEnabled             = whisperMetalEnabled
        self.whisperModelAutopick            = whisperModelAutopick
        self.diarizationEnabled              = diarizationEnabled
        self.diarizationModelDir             = diarizationModelDir
        self.diskGuardEnabled                = diskGuardEnabled
        self.diskGuardMinFreeGb              = diskGuardMinFreeGb
        self.diskWarnHudGb                   = diskWarnHudGb
        self.diskWarnModalGb                 = diskWarnModalGb
        self.mediaStorageCapGb               = mediaStorageCapGb
        self.mediaStorageCapEnabled          = mediaStorageCapEnabled
        self.sourcesInstagram                = sourcesInstagram
        self.instagramRate                   = instagramRate
        self.instagramFetchIntervalMinutes   = instagramFetchIntervalMinutes
        self.igDefaultReels                  = igDefaultReels
        self.igDefaultPosts                  = igDefaultPosts
        self.igDefaultStories                = igDefaultStories
        self.instagramStoriesIntervalMinutes = instagramStoriesIntervalMinutes
        self.proEntitlementStatus            = proEntitlementStatus
        self.proEntitlementCachedAt          = proEntitlementCachedAt
        self.lastUpsellShownAt               = lastUpsellShownAt
        self.disclaimerAcceptedAt            = disclaimerAcceptedAt
        self.disclaimerVersion               = disclaimerVersion
        self.dailyCheckEnabled               = dailyCheckEnabled
        self.upsellFrequency                 = upsellFrequency
        self.notifyMediaTypes                = notifyMediaTypes
        self.youtubeIncludeVideosDefault     = youtubeIncludeVideosDefault
        self.keywordWatch                    = keywordWatch
        self.tableLayouts                    = tableLayouts
        self.powerRevertPolicy               = powerRevertPolicy
        self.defaultStartupMode              = defaultStartupMode
        self.powerRevertAfterQueue           = powerRevertAfterQueue
        self.dailySummary                    = dailySummary
        self.openOnLastUsedTab               = openOnLastUsedTab
        self.startupTab                      = startupTab
        self.forwardToSystem                 = forwardToSystem
        self.showShortcutHints               = showShortcutHints
        self.updateIntervalWeekly            = updateIntervalWeekly
        self.autoInstallUpdates              = autoInstallUpdates
        self.updateRemindAfter               = updateRemindAfter
        self.skippedUpdateVersion            = skippedUpdateVersion
        self.youtubeCopyFormat               = youtubeCopyFormat
        self.youtubeLinkAction               = youtubeLinkAction
    }

    // MARK: - CodingKeys (camelCase ↔ snake_case YAML keys)

    enum CodingKeys: String, CodingKey {
        case outputRoot                     = "output_root"
        case dailyCheckTime                 = "daily_check_time"
        case catchUpMissed                  = "catch_up_missed"
        case updateCheckEnabled             = "update_check_enabled"
        case autoStartQueue                 = "auto_start_queue"
        case autoStartDelaySeconds          = "auto_start_delay_seconds"
        case notifyOnSuccess                = "notify_on_success"
        case setupCompleted                 = "setup_completed"
        case mp3RetentionDays               = "mp3_retention_days"
        case deleteMp3AfterTranscribe       = "delete_mp3_after_transcribe"
        case transcriptRetentionDays        = "transcript_retention_days"
        case bandwidthLimitMbps             = "bandwidth_limit_mbps"
        case loadLevel                      = "load_level"
        case obsidianVaultPath              = "obsidian_vault_path"
        case obsidianVaultName              = "obsidian_vault_name"
        case exportRoot                     = "export_root"
        case defaultExportFormat            = "default_export_format"
        case appLanguage                    = "app_language"
        case whisperModel                   = "whisper_model"
        case transcriptionEngine            = "transcription_engine"
        case fallbackEngine                 = "fallback_engine"
        case properNounCorrection           = "proper_noun_correction"
        case qwenModel                      = "qwen_model"
        case qwenForcedAlign                = "qwen_forced_align"
        case logRetentionDays               = "log_retention_days"
        case whisperFastMode                = "whisper_fast_mode"
        case rssConcurrency                 = "rss_concurrency"
        case downloadConcurrency            = "download_concurrency"
        case downloadConcurrencyPerHost     = "download_concurrency_per_host"
        case useEtagCache                   = "use_etag_cache"
        case libraryScanCache               = "library_scan_cache"
        case notifyMode                     = "notify_mode"
        case knowledgeHubRoot               = "knowledge_hub_root"
        case githubRepo                     = "github_repo"
        case saveSrt                        = "save_srt"
        case saveTxt                        = "save_txt"
        case saveHtml                       = "save_html"
        case saveOkf                        = "save_okf"
        case saveVtt                        = "save_vtt"
        case saveCsv                        = "save_csv"
        case sourcesPodcasts                = "sources_podcasts"
        case sourcesYoutube                 = "sources_youtube"
        case ytdlpLastSelfUpdateAt          = "ytdlp_last_self_update_at"
        case youtubeDefaultTranscriptSource = "youtube_default_transcript_source"
        case youtubeDefaultLanguage         = "youtube_default_language"
        case youtubeSkipShortsDefault       = "youtube_skip_shorts_default"
        case showLogDock                    = "show_log_dock"
        case runInBackground               = "run_in_background"
        case autoCheckForUpdates           = "auto_check_for_updates"
        case hasCompletedFirstRun          = "has_completed_first_run"
        case hideDockIconInBackground      = "hide_dock_icon_in_background"
        case connectivityMonitorEnabled     = "connectivity_monitor_enabled"
        case autoResumeFailedWindowHours    = "auto_resume_failed_window_hours"
        case watchFolderEnabled             = "watch_folder_enabled"
        case watchFolderRoot                = "watch_folder_root"
        case watchFolderPost                = "watch_folder_post"
        case localMaxDurationHours          = "local_max_duration_hours"
        case eventRetentionDays             = "event_retention_days"
        case notifyEvents                   = "notify_events"
        case notifyQuietHoursEnabled        = "notify_quiet_hours_enabled"
        case notifyQuietHoursStart          = "notify_quiet_hours_start"
        case notifyQuietHoursEnd            = "notify_quiet_hours_end"
        case webhooksEnabled                = "webhooks_enabled"
        case webhooks
        case notionEnabled                  = "notion_enabled"
        case notionAutoPush                 = "notion_auto_push"
        case notionDatabaseId               = "notion_database_id"
        case queueOrder                     = "queue_order"
        case backfillOrder                  = "backfill_order"
        case defaultMinDurationSec          = "default_min_duration_sec"
        case defaultMaxDurationSec          = "default_max_duration_sec"
        case captionFallbackMode            = "caption_fallback_mode"
        case confidenceMarkingEnabled       = "confidence_marking_enabled"
        case confidenceThreshold            = "confidence_threshold"
        case processingWindowsEnabled       = "processing_windows_enabled"
        case processingWindows              = "processing_windows"
        case pauseOnBattery                 = "pause_on_battery"
        case batteryLoadLevel               = "battery_load_level"
        case pauseQueueOnBattery            = "pause_queue_on_battery"
        case batteryPolicy                  = "battery_policy"
        case batteryModeBehavior            = "battery_mode_behavior"
        case transcribeConcurrency          = "transcribe_concurrency"
        case whisperMetalEnabled            = "whisper_metal_enabled"
        case whisperModelAutopick           = "whisper_model_autopick"
        case diarizationEnabled             = "diarization_enabled"
        case diarizationModelDir            = "diarization_model_dir"
        case diskGuardEnabled               = "disk_guard_enabled"
        case diskGuardMinFreeGb             = "disk_guard_min_free_gb"
        case diskWarnHudGb                  = "disk_warn_hud_gb"
        case diskWarnModalGb                = "disk_warn_modal_gb"
        case mediaStorageCapGb              = "media_storage_cap_gb"
        case mediaStorageCapEnabled         = "media_storage_cap_enabled"
        // v2-only
        case sourcesInstagram               = "sources_instagram"
        case instagramRate                  = "instagram_rate"
        case igDefaultReels                 = "ig_default_reels"
        case igDefaultPosts                 = "ig_default_posts"
        case igDefaultStories               = "ig_default_stories"
        case instagramStoriesIntervalMinutes = "instagram_stories_interval_minutes"
        case proEntitlementStatus           = "pro_entitlement_status"
        case proEntitlementCachedAt         = "pro_entitlement_cached_at"
        case lastUpsellShownAt              = "last_upsell_shown_at"
        case disclaimerAcceptedAt           = "disclaimer_accepted_at"
        case disclaimerVersion              = "disclaimer_version"
        case dailyCheckEnabled              = "daily_check_enabled"
        // v2-only, oracle-excluded (no Python model counterpart)
        case upsellFrequency                = "upsell_frequency"
        case keywordWatch                   = "keyword_watch"
        case tableLayouts                   = "table_layouts"
        // v2-only, mode & performance (oracle-excluded)
        case powerRevertPolicy              = "power_revert_policy"
        case defaultStartupMode             = "default_startup_mode"
        case powerRevertAfterQueue          = "power_revert_after_queue"
        // v2-only, Welle N (oracle-excluded)
        case dailySummary                   = "daily_summary"
        // v2-only, Welle V (oracle-excluded)
        case openOnLastUsedTab              = "open_on_last_used_tab"
        case startupTab                     = "startup_tab"
        // Welle D1 additions (oracle-excluded)
        case instagramFetchIntervalMinutes  = "instagram_fetch_interval_minutes"
        case notifyMediaTypes               = "notify_media_types"
        case youtubeIncludeVideosDefault    = "youtube_include_videos_default"
        // Welle system-notifications (oracle-excluded)
        case forwardToSystem                = "forward_to_system"
        // v2-only, quick-nav shortcut hints (oracle-excluded)
        case showShortcutHints              = "show_shortcut_hints"
        // v2-only, Update UX (Task A1, oracle-excluded)
        case updateIntervalWeekly           = "update_interval_weekly"
        case autoInstallUpdates             = "auto_install_updates"
        case updateRemindAfter              = "update_remind_after"
        case skippedUpdateVersion           = "skipped_update_version"
        case youtubeCopyFormat              = "youtube_copy_format"
        case youtubeLinkAction              = "youtube_link_action"
    }

    // MARK: - Custom decode (every missing key → Python-matching default)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        outputRoot                     = try c.decodeIfPresent(String.self,            forKey: .outputRoot)                     ?? Self.defaultOutputRoot
        let rawTime                    = try c.decodeIfPresent(String.self,            forKey: .dailyCheckTime)                 ?? Self.defaultDailyCheckTime
        guard Self.isValidHHMM(rawTime) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.dailyCheckTime],
                      debugDescription: "invalid HH:MM time: \"\(rawTime)\"")
            )
        }
        dailyCheckTime                 = rawTime
        catchUpMissed                  = try c.decodeIfPresent(Bool.self,              forKey: .catchUpMissed)                  ?? Self.defaultCatchUpMissed
        updateCheckEnabled             = try c.decodeIfPresent(Bool.self,              forKey: .updateCheckEnabled)             ?? Self.defaultUpdateCheckEnabled
        autoStartQueue                 = try c.decodeIfPresent(Bool.self,              forKey: .autoStartQueue)                 ?? Self.defaultAutoStartQueue
        autoStartDelaySeconds          = try c.decodeIfPresent(Int.self,               forKey: .autoStartDelaySeconds)          ?? Self.defaultAutoStartDelaySeconds
        notifyOnSuccess                = try c.decodeIfPresent(Bool.self,              forKey: .notifyOnSuccess)                ?? Self.defaultNotifyOnSuccess
        setupCompleted                 = try c.decodeIfPresent(Bool.self,              forKey: .setupCompleted)                 ?? Self.defaultSetupCompleted
        mp3RetentionDays               = try c.decodeIfPresent(Int.self,               forKey: .mp3RetentionDays)               ?? Self.defaultMp3RetentionDays
        deleteMp3AfterTranscribe       = try c.decodeIfPresent(Bool.self,              forKey: .deleteMp3AfterTranscribe)       ?? Self.defaultDeleteMp3AfterTranscribe
        transcriptRetentionDays        = try c.decodeIfPresent(Int.self,               forKey: .transcriptRetentionDays)        ?? Self.defaultTranscriptRetentionDays
        bandwidthLimitMbps             = try c.decodeIfPresent(Int.self,               forKey: .bandwidthLimitMbps)             ?? Self.defaultBandwidthLimitMbps

        // loadLevel: apply legacy migration if key is absent
        let rawLoadLevel               = try c.decodeIfPresent(String.self,            forKey: .loadLevel)
        if let ll = rawLoadLevel {
            loadLevel = ll
        } else {
            // Replicate _migrate_load_level: absent load_level + legacy parallel_transcribe int
            // The migration is applied at the dict level before decoding in Python; here we
            // peek at the extra key via a generic decoder fallback.
            loadLevel = Self.defaultLoadLevel
        }

        obsidianVaultPath              = try c.decodeIfPresent(String.self,            forKey: .obsidianVaultPath)              ?? Self.defaultObsidianVaultPath
        obsidianVaultName              = try c.decodeIfPresent(String.self,            forKey: .obsidianVaultName)              ?? Self.defaultObsidianVaultName
        exportRoot                     = try c.decodeIfPresent(String.self,            forKey: .exportRoot)                     ?? Self.defaultExportRoot
        defaultExportFormat            = try c.decodeIfPresent(String.self,            forKey: .defaultExportFormat)            ?? Self.defaultDefaultExportFormat
        appLanguage                    = try c.decodeIfPresent(String.self,            forKey: .appLanguage)                    ?? Self.defaultAppLanguage
        whisperModel                   = try c.decodeIfPresent(String.self,            forKey: .whisperModel)                   ?? Self.defaultWhisperModel
        transcriptionEngine            = try c.decodeIfPresent(String.self,            forKey: .transcriptionEngine)            ?? Self.defaultTranscriptionEngine
        fallbackEngine                 = try c.decodeIfPresent(String.self,            forKey: .fallbackEngine)                 ?? Self.defaultFallbackEngine
        properNounCorrection           = try c.decodeIfPresent(String.self,            forKey: .properNounCorrection)           ?? Self.defaultProperNounCorrection
        qwenModel                      = try c.decodeIfPresent(String.self,            forKey: .qwenModel)                      ?? Self.defaultQwenModel
        qwenForcedAlign                = try c.decodeIfPresent(Bool.self,              forKey: .qwenForcedAlign)                ?? Self.defaultQwenForcedAlign
        logRetentionDays               = try c.decodeIfPresent(Int.self,               forKey: .logRetentionDays)               ?? Self.defaultLogRetentionDays
        whisperFastMode                = try c.decodeIfPresent(Bool.self,              forKey: .whisperFastMode)                ?? Self.defaultWhisperFastMode
        rssConcurrency                 = try c.decodeIfPresent(Int.self,               forKey: .rssConcurrency)                 ?? Self.defaultRssConcurrency
        downloadConcurrency            = try c.decodeIfPresent(Int.self,               forKey: .downloadConcurrency)            ?? Self.defaultDownloadConcurrency
        downloadConcurrencyPerHost     = try c.decodeIfPresent(Int.self,               forKey: .downloadConcurrencyPerHost)     ?? Self.defaultDownloadConcurrencyPerHost
        useEtagCache                   = try c.decodeIfPresent(Bool.self,              forKey: .useEtagCache)                   ?? Self.defaultUseEtagCache
        libraryScanCache               = try c.decodeIfPresent(Bool.self,              forKey: .libraryScanCache)               ?? Self.defaultLibraryScanCache
        notifyMode                     = try c.decodeIfPresent(String.self,            forKey: .notifyMode)                     ?? Self.defaultNotifyMode
        knowledgeHubRoot               = try c.decodeIfPresent(String.self,            forKey: .knowledgeHubRoot)               ?? Self.defaultKnowledgeHubRoot
        githubRepo                     = try c.decodeIfPresent(String.self,            forKey: .githubRepo)                     ?? Self.defaultGithubRepo
        saveSrt                        = try c.decodeIfPresent(Bool.self,              forKey: .saveSrt)                        ?? Self.defaultSaveSrt
        saveTxt                        = try c.decodeIfPresent(Bool.self,              forKey: .saveTxt)                        ?? Self.defaultSaveTxt
        saveHtml                       = try c.decodeIfPresent(Bool.self,              forKey: .saveHtml)                       ?? Self.defaultSaveHtml
        saveOkf                        = try c.decodeIfPresent(Bool.self,              forKey: .saveOkf)                        ?? Self.defaultSaveOkf
        saveVtt                        = try c.decodeIfPresent(Bool.self,              forKey: .saveVtt)                        ?? Self.defaultSaveVtt
        saveCsv                        = try c.decodeIfPresent(Bool.self,              forKey: .saveCsv)                        ?? Self.defaultSaveCsv
        sourcesPodcasts                = try c.decodeIfPresent(Bool.self,              forKey: .sourcesPodcasts)                ?? Self.defaultSourcesPodcasts
        sourcesYoutube                 = try c.decodeIfPresent(Bool.self,              forKey: .sourcesYoutube)                 ?? Self.defaultSourcesYoutube
        ytdlpLastSelfUpdateAt          = try c.decodeIfPresent(String.self,            forKey: .ytdlpLastSelfUpdateAt)          ?? Self.defaultYtdlpLastSelfUpdateAt
        youtubeDefaultTranscriptSource = try c.decodeIfPresent(String.self,            forKey: .youtubeDefaultTranscriptSource) ?? Self.defaultYoutubeDefaultTranscriptSource
        youtubeDefaultLanguage         = try c.decodeIfPresent(String.self,            forKey: .youtubeDefaultLanguage)         ?? Self.defaultYoutubeDefaultLanguage
        youtubeSkipShortsDefault       = try c.decodeIfPresent(Bool.self,              forKey: .youtubeSkipShortsDefault)       ?? Self.defaultYoutubeSkipShortsDefault
        showLogDock                    = try c.decodeIfPresent(Bool.self,              forKey: .showLogDock)                    ?? Self.defaultShowLogDock
        runInBackground              = try c.decodeIfPresent(Bool.self, forKey: .runInBackground)              ?? Self.defaultRunInBackground
        autoCheckForUpdates          = try c.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates)          ?? Self.defaultAutoCheckForUpdates
        hideDockIconInBackground     = try c.decodeIfPresent(Bool.self, forKey: .hideDockIconInBackground)     ?? Self.defaultHideDockIconInBackground
        connectivityMonitorEnabled     = try c.decodeIfPresent(Bool.self,              forKey: .connectivityMonitorEnabled)     ?? Self.defaultConnectivityMonitorEnabled
        autoResumeFailedWindowHours    = try c.decodeIfPresent(Int.self,               forKey: .autoResumeFailedWindowHours)    ?? Self.defaultAutoResumeFailedWindowHours
        watchFolderEnabled             = try c.decodeIfPresent(Bool.self,              forKey: .watchFolderEnabled)             ?? Self.defaultWatchFolderEnabled
        watchFolderRoot                = try c.decodeIfPresent(String.self,            forKey: .watchFolderRoot)                ?? Self.defaultWatchFolderRoot
        watchFolderPost                = try c.decodeIfPresent(String.self,            forKey: .watchFolderPost)                ?? Self.defaultWatchFolderPost
        localMaxDurationHours          = try c.decodeIfPresent(Int.self,               forKey: .localMaxDurationHours)          ?? Self.defaultLocalMaxDurationHours
        eventRetentionDays             = try c.decodeIfPresent(Int.self,               forKey: .eventRetentionDays)             ?? Self.defaultEventRetentionDays
        notifyEvents                   = try c.decodeIfPresent([String: Bool].self,    forKey: .notifyEvents)                   ?? Self.defaultNotifyEvents
        notifyQuietHoursEnabled        = try c.decodeIfPresent(Bool.self,              forKey: .notifyQuietHoursEnabled)        ?? Self.defaultNotifyQuietHoursEnabled
        // Quiet-hours times: sanitize to the default when the stored value is not
        // a valid "HH:mm" (unlike dailyCheckTime we do NOT throw — a bad quiet-hours
        // string must not fail the whole settings load, which would reset every
        // other setting). An unsanitised "25:99" would otherwise reach HHmmField
        // and be silently normalised by Calendar into a nonsense schedule.
        let rawQHStart                 = try c.decodeIfPresent(String.self,            forKey: .notifyQuietHoursStart)          ?? Self.defaultNotifyQuietHoursStart
        notifyQuietHoursStart          = Self.isValidHHMM(rawQHStart) ? rawQHStart : Self.defaultNotifyQuietHoursStart
        let rawQHEnd                   = try c.decodeIfPresent(String.self,            forKey: .notifyQuietHoursEnd)            ?? Self.defaultNotifyQuietHoursEnd
        notifyQuietHoursEnd            = Self.isValidHHMM(rawQHEnd) ? rawQHEnd : Self.defaultNotifyQuietHoursEnd
        webhooksEnabled                = try c.decodeIfPresent(Bool.self,              forKey: .webhooksEnabled)                ?? Self.defaultWebhooksEnabled
        webhooks                       = try c.decodeIfPresent([WebhookEntry].self,    forKey: .webhooks)                       ?? Self.defaultWebhooks
        notionEnabled                  = try c.decodeIfPresent(Bool.self,              forKey: .notionEnabled)                  ?? Self.defaultNotionEnabled
        notionAutoPush                 = try c.decodeIfPresent(Bool.self,              forKey: .notionAutoPush)                 ?? Self.defaultNotionAutoPush
        notionDatabaseId               = try c.decodeIfPresent(String.self,            forKey: .notionDatabaseId)               ?? Self.defaultNotionDatabaseId
        queueOrder                     = try c.decodeIfPresent(String.self,            forKey: .queueOrder)                     ?? Self.defaultQueueOrder
        backfillOrder                  = try c.decodeIfPresent(String.self,            forKey: .backfillOrder)                  ?? Self.defaultBackfillOrder
        defaultMinDurationSec          = try c.decodeIfPresent(Int.self,               forKey: .defaultMinDurationSec)          ?? Self.defaultDefaultMinDurationSec
        defaultMaxDurationSec          = try c.decodeIfPresent(Int.self,               forKey: .defaultMaxDurationSec)          ?? Self.defaultDefaultMaxDurationSec
        captionFallbackMode            = try c.decodeIfPresent(String.self,            forKey: .captionFallbackMode)            ?? Self.defaultCaptionFallbackMode
        confidenceMarkingEnabled       = try c.decodeIfPresent(Bool.self,              forKey: .confidenceMarkingEnabled)       ?? Self.defaultConfidenceMarkingEnabled
        confidenceThreshold            = try c.decodeIfPresent(Double.self,            forKey: .confidenceThreshold)            ?? Self.defaultConfidenceThreshold
        processingWindowsEnabled       = try c.decodeIfPresent(Bool.self,              forKey: .processingWindowsEnabled)       ?? Self.defaultProcessingWindowsEnabled
        processingWindows              = try c.decodeIfPresent([String].self,          forKey: .processingWindows)              ?? Self.defaultProcessingWindows
        pauseOnBattery                 = try c.decodeIfPresent(Bool.self,              forKey: .pauseOnBattery)                 ?? Self.defaultPauseOnBattery
        batteryLoadLevel               = try c.decodeIfPresent(String.self,            forKey: .batteryLoadLevel)               ?? Self.defaultBatteryLoadLevel
        pauseQueueOnBattery            = try c.decodeIfPresent(Bool.self,              forKey: .pauseQueueOnBattery)            ?? Self.defaultPauseQueueOnBattery
        // batteryPolicy supersedes the three legacy fields. If absent, migrate from
        // an existing config (pauseQueueOnBattery → finish_then_pause / normal); a
        // fresh install (no legacy keys either) gets the default finish_then_pause.
        if let bp = try c.decodeIfPresent(String.self, forKey: .batteryPolicy) {
            batteryPolicy = bp
        } else if c.contains(.pauseQueueOnBattery) || c.contains(.pauseOnBattery) {
            batteryPolicy = pauseQueueOnBattery
                ? BatteryPolicy.finishThenPause.rawValue
                : BatteryPolicy.normal.rawValue
        } else {
            batteryPolicy = Self.defaultBatteryPolicy
        }
        batteryModeBehavior            = try c.decodeIfPresent(String.self,            forKey: .batteryModeBehavior)            ?? Self.defaultBatteryModeBehavior
        transcribeConcurrency          = try c.decodeIfPresent(Int.self,               forKey: .transcribeConcurrency)          ?? Self.defaultTranscribeConcurrency
        whisperMetalEnabled            = try c.decodeIfPresent(Bool.self,              forKey: .whisperMetalEnabled)            ?? Self.defaultWhisperMetalEnabled
        whisperModelAutopick           = try c.decodeIfPresent(Bool.self,              forKey: .whisperModelAutopick)           ?? Self.defaultWhisperModelAutopick
        diarizationEnabled             = try c.decodeIfPresent(Bool.self,              forKey: .diarizationEnabled)             ?? Self.defaultDiarizationEnabled
        diarizationModelDir            = try c.decodeIfPresent(String.self,            forKey: .diarizationModelDir)            ?? Self.defaultDiarizationModelDir
        diskGuardEnabled               = try c.decodeIfPresent(Bool.self,              forKey: .diskGuardEnabled)               ?? Self.defaultDiskGuardEnabled
        diskGuardMinFreeGb             = try c.decodeIfPresent(Int.self,               forKey: .diskGuardMinFreeGb)             ?? Self.defaultDiskGuardMinFreeGb
        diskWarnHudGb                  = try c.decodeIfPresent(Int.self,               forKey: .diskWarnHudGb)                  ?? Self.defaultDiskWarnHudGb
        diskWarnModalGb                = try c.decodeIfPresent(Int.self,               forKey: .diskWarnModalGb)                ?? Self.defaultDiskWarnModalGb
        mediaStorageCapGb              = try c.decodeIfPresent(Int.self,               forKey: .mediaStorageCapGb)              ?? Self.defaultMediaStorageCapGb
        mediaStorageCapEnabled         = try c.decodeIfPresent(Bool.self,              forKey: .mediaStorageCapEnabled)         ?? Self.defaultMediaStorageCapEnabled
        // v2-only
        sourcesInstagram               = try c.decodeIfPresent(Bool.self,              forKey: .sourcesInstagram)               ?? Self.defaultSourcesInstagram
        instagramRate                  = try c.decodeIfPresent(String.self,            forKey: .instagramRate)                  ?? Self.defaultInstagramRate
        instagramFetchIntervalMinutes  = try c.decodeIfPresent(Int.self,               forKey: .instagramFetchIntervalMinutes)  ?? Self.defaultInstagramFetchIntervalMinutes
        igDefaultReels                 = try c.decodeIfPresent(Bool.self,              forKey: .igDefaultReels)                 ?? Self.defaultIgDefaultReels
        igDefaultPosts                 = try c.decodeIfPresent(Bool.self,              forKey: .igDefaultPosts)                 ?? Self.defaultIgDefaultPosts
        igDefaultStories               = try c.decodeIfPresent(Bool.self,              forKey: .igDefaultStories)               ?? Self.defaultIgDefaultStories
        instagramStoriesIntervalMinutes = try c.decodeIfPresent(Int.self,              forKey: .instagramStoriesIntervalMinutes) ?? Self.defaultInstagramStoriesIntervalMinutes
        proEntitlementStatus           = try c.decodeIfPresent(String.self,            forKey: .proEntitlementStatus)           ?? Self.defaultProEntitlementStatus
        proEntitlementCachedAt         = try c.decodeIfPresent(String.self,            forKey: .proEntitlementCachedAt)         ?? Self.defaultProEntitlementCachedAt
        lastUpsellShownAt              = try c.decodeIfPresent(String.self,            forKey: .lastUpsellShownAt)              ?? Self.defaultLastUpsellShownAt
        disclaimerAcceptedAt           = try c.decodeIfPresent(String.self,            forKey: .disclaimerAcceptedAt)           ?? Self.defaultDisclaimerAcceptedAt
        // Migration: upgrading installs that already accepted the disclaimer (i.e.
        // already ran the first-run wizard pre-this-flag) must not silently lose
        // background-mode/login-item management — backfill `true` for them. Only
        // genuinely fresh installs (empty disclaimerAcceptedAt) default to `false`.
        hasCompletedFirstRun          = try c.decodeIfPresent(Bool.self,               forKey: .hasCompletedFirstRun)           ?? !disclaimerAcceptedAt.isEmpty
        disclaimerVersion              = try c.decodeIfPresent(String.self,            forKey: .disclaimerVersion)              ?? Self.defaultDisclaimerVersion
        dailyCheckEnabled              = try c.decodeIfPresent(Bool.self,              forKey: .dailyCheckEnabled)              ?? Self.defaultDailyCheckEnabled
        // v2-only, oracle-excluded
        upsellFrequency               = try c.decodeIfPresent(String.self,             forKey: .upsellFrequency)               ?? Self.defaultUpsellFrequency
        // keywordWatch migrated from [String] → [WatchTerm]. Decode the new shape;
        // fall back to the legacy string array (each becomes a plain, enabled term).
        if c.contains(.keywordWatch) {
            if let terms = try? c.decode([WatchTerm].self, forKey: .keywordWatch) {
                keywordWatch = terms
            } else if let legacy = try? c.decode([String].self, forKey: .keywordWatch) {
                keywordWatch = legacy.map { WatchTerm(id: UUID().uuidString, term: $0) }
            } else {
                keywordWatch = Self.defaultKeywordWatch
            }
        } else {
            keywordWatch = Self.defaultKeywordWatch
        }
        // Table layouts are a large, app-generated blob (native TableColumnCustomization)
        // and the field most likely to drift across app versions. Decode it LENIENTLY:
        // a malformed blob falls back to defaults instead of throwing — a strict
        // decode here would fail the entire settings load and silently reset EVERY
        // setting (LiveDataLoader falls back to Settings()). Losing table columns is
        // an acceptable degradation; losing all settings is not.
        if let decodedLayouts = (try? c.decodeIfPresent([String: TableLayout].self, forKey: .tableLayouts)) ?? nil {
            tableLayouts = decodedLayouts
        } else {
            tableLayouts = Self.defaultTableLayouts
        }
        // v2-only, mode & performance (oracle-excluded)
        powerRevertPolicy             = try c.decodeIfPresent(String.self,             forKey: .powerRevertPolicy)             ?? Self.defaultPowerRevertPolicy
        defaultStartupMode            = try c.decodeIfPresent(String.self,             forKey: .defaultStartupMode)            ?? Self.defaultDefaultStartupMode
        powerRevertAfterQueue         = try c.decodeIfPresent(Bool.self,               forKey: .powerRevertAfterQueue)         ?? Self.defaultPowerRevertAfterQueue
        // v2-only, Welle N (oracle-excluded)
        dailySummary                  = try c.decodeIfPresent(Bool.self,               forKey: .dailySummary)                  ?? Self.defaultDailySummary
        // v2-only, Welle V (oracle-excluded)
        openOnLastUsedTab             = try c.decodeIfPresent(Bool.self,               forKey: .openOnLastUsedTab)             ?? Self.defaultOpenOnLastUsedTab
        startupTab                    = try c.decodeIfPresent(String.self,             forKey: .startupTab)                    ?? Self.defaultStartupTab
        // Welle D1 additions (oracle-excluded)
        notifyMediaTypes              = try c.decodeIfPresent([String].self,           forKey: .notifyMediaTypes)              ?? Self.defaultNotifyMediaTypes
        youtubeIncludeVideosDefault   = try c.decodeIfPresent(Bool.self,              forKey: .youtubeIncludeVideosDefault)   ?? Self.defaultYoutubeIncludeVideosDefault
        // Welle system-notifications (oracle-excluded)
        forwardToSystem               = try c.decodeIfPresent([String: Bool].self,    forKey: .forwardToSystem)               ?? Self.defaultForwardToSystem
        // v2-only, quick-nav shortcut hints (oracle-excluded)
        showShortcutHints             = try c.decodeIfPresent(Bool.self,               forKey: .showShortcutHints)             ?? Self.defaultShowShortcutHints
        // v2-only, Update UX (Task A1, oracle-excluded)
        updateIntervalWeekly          = try c.decodeIfPresent(Bool.self,               forKey: .updateIntervalWeekly)          ?? Self.defaultUpdateIntervalWeekly
        autoInstallUpdates            = try c.decodeIfPresent(Bool.self,               forKey: .autoInstallUpdates)            ?? Self.defaultAutoInstallUpdates
        updateRemindAfter             = try c.decodeIfPresent(Date.self,               forKey: .updateRemindAfter)             ?? Self.defaultUpdateRemindAfter
        skippedUpdateVersion          = try c.decodeIfPresent(String.self,             forKey: .skippedUpdateVersion)          ?? Self.defaultSkippedUpdateVersion

        // v2-only, Welle YT-Explorer (oracle-excluded)
        youtubeCopyFormat            = try c.decodeIfPresent(String.self, forKey: .youtubeCopyFormat)            ?? Self.defaultYoutubeCopyFormat
        youtubeLinkAction            = try c.decodeIfPresent(YouTubeLinkAction.self, forKey: .youtubeLinkAction) ?? Self.defaultYoutubeLinkAction
    }

    // MARK: - Validation helpers

    /// Validates the HH:MM format used for ``dailyCheckTime`` and quiet-hour fields.
    /// Replicates Python's `_TIME_RE = ^([01]\d|2[0-3]):[0-5]\d$`.
    public static func isValidHHMM(_ value: String) -> Bool {
        let nsValue = value as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^([01]\d|2[0-3]):[0-5]\d$"#) else { return false }
        let range = NSRange(location: 0, length: nsValue.length)
        return regex.firstMatch(in: value, range: range) != nil
    }

    // MARK: - Legacy load_level migration
    //
    // Python's `_migrate_load_level(data)` runs on the raw dict *before*
    // Pydantic validation.  We replicate it here as a static helper so
    // `SettingsStore.load(from:)` can apply it before decoding.
    //
    // Rules:
    //   • If `load_level` key is already present → no-op.
    //   • If `parallel_transcribe` (Int) is present → map ≥2 → "full", else "balanced".
    public static func migratingLoadLevel(in yaml: String) throws -> String {
        guard var node = try Yams.compose(yaml: yaml) else { return yaml }
        guard var mapping = node.mapping else { return yaml }

        // Already has load_level — no-op.
        if mapping["load_level"] != nil { return yaml }

        // Look for legacy parallel_transcribe int.
        if let ptNode = mapping["parallel_transcribe"],
           case .scalar(let sv) = ptNode,
           let n = Int(sv.string) {
            let level: String = n >= 2 ? "full" : "balanced"
            mapping["load_level"] = Node(level)
            node.mapping = mapping
            return try Yams.serialize(node: node)
        }
        return yaml
    }

    // MARK: - backfill_setup_completed

    /// Replicates Python `backfill_setup_completed(s)`:
    /// if `setup_completed` is already true, returns `s` unchanged.
    /// Otherwise, if any of `output_root`, `obsidian_vault_path`, or
    /// `knowledge_hub_root` differs from the Python defaults, flips
    /// `setup_completed` to true.
    public func applyingBackfillSetupCompleted() -> Settings {
        guard !setupCompleted else { return self }
        let customised =
            outputRoot      != Self.defaultOutputRoot      ||
            obsidianVaultPath != Self.defaultObsidianVaultPath ||
            knowledgeHubRoot != Self.defaultKnowledgeHubRoot
        if customised {
            var copy = self
            copy.setupCompleted = true
            return copy
        }
        return self
    }
}
