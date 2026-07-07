import Foundation

// MARK: - JSONValue

/// A typed JSON value that can be stored in ``Event/payload`` and round-tripped
/// to/from the `payload_json` TEXT column in the `events` table.
///
/// ## Design choice
///
/// The Python `Event.payload` is `dict[str, Any]` — arbitrary JSON. To
/// preserve full fidelity (numbers, booleans, nested arrays/objects, null) a
/// `[String: String]` map is not enough. This recursive enum covers the full
/// JSON value space and satisfies `Sendable`, `Equatable`, and `Codable` so it
/// round-trips cleanly through the database column and across actor boundaries.
public indirect enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let n = try? container.decode(Double.self) {
            self = .number(n)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot decode JSONValue"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):  try container.encode(s)
        case .number(let n):  try container.encode(n)
        case .bool(let b):    try container.encode(b)
        case .null:           try container.encodeNil()
        case .array(let a):   try container.encode(a)
        case .object(let o):  try container.encode(o)
        }
    }
}

// MARK: - EventType

/// String constants for event types, grouped by domain.
///
/// These exact strings are written to the `events.type` column and **must
/// match the Python `EventType` class byte-for-byte**. Do not rename or
/// re-case without coordinating with the Python side.
public enum EventType {
    // Episode lifecycle
    public static let episodeDiscovered       = "episode.discovered"
    public static let episodeDownloadStarted  = "episode.download_started"
    public static let episodeDownloaded       = "episode.downloaded"
    public static let episodeTranscribeStarted = "episode.transcribe_started"
    public static let episodeTranscribed      = "episode.transcribed"
    public static let episodeFailed           = "episode.failed"
    public static let episodeSkipped          = "episode.skipped"
    public static let episodeDeferred         = "episode.deferred"

    // Run / queue
    public static let runStarted    = "run.started"
    public static let runFinished   = "run.finished"
    public static let queueSized    = "queue.sized"
    public static let queuePaused   = "queue.paused"
    public static let queueResumed  = "queue.resumed"
    /// M12: emitted when the queue is (or is about to be) paused because the disk
    /// is full — either a download hit `ENOSPC` mid-write, or the pre-claim
    /// `DiskGuard` check found free space below the floor. The UI layer
    /// (`QueueController`) subscribes and pauses the queue + raises the low-disk
    /// banner. Optional payload `freeGb` (String) carries the observed free space.
    public static let queueDiskFull = "queue.disk_full"

    // Up Next (user queue curation — durable audit of manual queue changes).
    // Payload: `count` (number), `guids` (array of strings); `queueUpNextAdded`
    // additionally carries `position` ("top" | "bottom"). Emitted once per batch
    // action, post-commit, only when at least one row actually changed.
    public static let queueUpNextAdded     = "queue.upnext_added"
    public static let queueUpNextRemoved   = "queue.upnext_removed"
    public static let queueUpNextReordered = "queue.upnext_reordered"

    // Feed
    public static let feedChecked   = "feed.checked"
    public static let feedUnchanged = "feed.unchanged"
    public static let feedError     = "feed.error"

    // Show
    public static let showAdded    = "show.added"
    public static let showRemoved  = "show.removed"
    public static let showEnabled  = "show.enabled"
    public static let showDisabled = "show.disabled"

    // Settings
    public static let settingsChanged = "settings.changed"

    // Progress (in-flight only; not persisted to the events table)
    /// Emitted by the pipeline while an episode is downloading or transcribing.
    /// Payload keys: `"phase"` (String: "downloading" | "transcribing"),
    /// `"fraction"` (Double 0.0–1.0).
    public static let episodeProgress = "episode.progress"
}

// MARK: - Event

/// A single lifecycle event emitted by the Vocateca pipeline, feed scanner,
/// worker, or UI layer.
///
/// Maps field-for-field onto the Python `core.events.Event` dataclass. The
/// `payload` uses ``JSONValue`` so arbitrary JSON objects survive round-trips
/// to the `payload_json` TEXT column without losing type information.
///
/// ## nowISO()
///
/// `nowISO()` returns the current UTC time formatted as
/// `2026-06-27T22:13:52+00:00` — **seconds** precision with a literal
/// `+00:00` suffix. This matches Python's
/// `datetime.now(timezone.utc).isoformat(timespec="seconds")` exactly.
///
/// `ISO8601DateFormatter` with `.withInternetDateTime` emits `Z` rather than
/// `+00:00`. To match Python we build the string manually from `Calendar`
/// components in UTC so the suffix is always `+00:00`.
public struct Event: Sendable, Equatable {

    // MARK: Fields

    /// The event type string (one of the ``EventType`` constants).
    public let type: String

    /// ISO-8601 UTC timestamp, seconds precision, `+00:00` suffix.
    /// Example: `2026-06-27T22:13:52+00:00`.
    public let ts: String

    /// Optional show slug the event belongs to.
    public let showSlug: String?

    /// Optional episode guid the event belongs to.
    public let guid: String?

    /// Arbitrary JSON payload. Defaults to an empty object.
    public let payload: [String: JSONValue]

    // MARK: Initialisers

    /// Creates an event with an explicit timestamp. Prefer the other init
    /// which fills `ts` from ``nowISO()`` automatically.
    public init(
        type: String,
        ts: String,
        showSlug: String? = nil,
        guid: String? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.ts = ts
        self.showSlug = showSlug
        self.guid = guid
        self.payload = payload
    }

    /// Creates an event, setting `ts` to the current UTC time via ``nowISO()``.
    public init(
        type: String,
        showSlug: String? = nil,
        guid: String? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.init(
            type: type,
            ts: Event.nowISO(),
            showSlug: showSlug,
            guid: guid,
            payload: payload
        )
    }

    // MARK: - nowISO()

    /// Returns the current time in UTC formatted as `YYYY-MM-DDTHH:MM:SS+00:00`.
    ///
    /// ## Format parity with Python
    ///
    /// Python: `datetime.now(timezone.utc).isoformat(timespec="seconds")`
    /// → `2026-06-27T22:13:52+00:00`
    ///
    /// `ISO8601DateFormatter` would emit `2026-06-27T22:13:52Z`. To produce
    /// the `+00:00` suffix instead, we extract UTC components manually and
    /// format with `String(format:)`. This is a one-liner and guaranteed
    /// stable regardless of locale or timezone settings.
    public static func nowISO() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date()
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
            comps.year!,
            comps.month!,
            comps.day!,
            comps.hour!,
            comps.minute!,
            comps.second!
        )
    }

    /// Formats `date` in the SAME `+00:00`, no-fractional-seconds UTC form as
    /// ``nowISO()``. Kept byte-identical so timestamps written by both are
    /// **lexically comparable** (string `<`), which the trash purge / deferred-media
    /// sweeps rely on when comparing `deleted_at` / `ready_at` against a cutoff.
    public static func iso(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
            comps.year!, comps.month!, comps.day!, comps.hour!, comps.minute!, comps.second!)
    }

    /// Parses an ISO-8601 timestamp (any of the forms the app writes) to a `Date`,
    /// falling back to `now` if unparseable so callers never crash on a bad clock.
    /// Delegates to the tolerant ``FeedBackoff/parseISO8601(_:)``.
    public static func date(fromISO s: String) -> Date {
        FeedBackoff.parseISO8601(s) ?? Date()
    }

    // MARK: - Persistence helpers

    /// Returns the `payload` encoded as compact JSON for writing to the
    /// `events.payload_json` column. Returns `"{}"` when payload is empty.
    public func payloadJSONString() -> String {
        guard !payload.isEmpty else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = []  // compact (no pretty-print)
        // Encode via a wrapper: JSONValue.object(_:) is Encodable.
        if let data = try? encoder.encode(JSONValue.object(payload)),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
