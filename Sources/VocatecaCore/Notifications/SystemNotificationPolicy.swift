import Foundation

// MARK: - NotifKindKey

/// Stable string identifiers for each in-app notification kind.
///
/// Lives in `VocatecaCore` so the pure forwarding policy can be tested without
/// importing VocatecaUI.  `NotifKind` (the UI-layer enum) maps to these keys via
/// its `.key` property.
///
/// Keys are intentionally camelCase to match the `kind` strings already persisted
/// in `NotificationsDatabase` (e.g. `"newEpisode"`, `"dailySummary"` etc.).
public enum NotifKindKey: String, CaseIterable, Sendable {
    case accountSuspended = "accountSuspended"
    case accountReauth    = "accountReauth"
    case keywordHit       = "keywordHit"
    case runFinished      = "runFinished"
    case backfillDone     = "backfillDone"
    case failure          = "failure"
    case newEpisode       = "newEpisode"
    case dailySummary     = "dailySummary"
    /// Informational: pipeline skipped because no speech was detected (e.g. music).
    case skippedNoSpeech  = "skippedNoSpeech"
    /// A transcription model finished downloading and is ready to use.
    case modelReady       = "modelReady"
    /// The media folder crossed 90% of the configured storage cap (§2 of the
    /// media-retention brief). Informational — no user action required.
    case storageWarning   = "storageWarning"
    /// The storage-cap maintenance pass evicted one or more old media files to
    /// get back under the cap. Informational.
    case mediaEvicted     = "mediaEvicted"
}

// MARK: - SystemNotificationPolicy

/// Pure, side-effect-free policy that decides whether a given notification kind
/// should be forwarded to the macOS Notification Center.
///
/// ## Defaults (when the user has set no per-kind override)
/// | Kind             | Free  | Pro   |
/// |------------------|-------|-------|
/// | accountSuspended | false | false |
/// | accountReauth    | false | false |
/// | keywordHit       | false | false |
/// | runFinished      | false | false |
/// | backfillDone     | false | false |
/// | failure          | false | false |
/// | newEpisode       | false | false |
/// | dailySummary     | **true** | **true** |
///
/// The per-kind map uses ``NotifKindKey`` raw-value strings as keys, matching
/// the `forwardToSystem` field in `AppSettings` and the `kind` column in the
/// notifications DB.
public enum SystemNotificationPolicy {

    // MARK: - Public API

    /// Whether to forward `kind` to the macOS Notification Center.
    ///
    /// - Parameters:
    ///   - kind:    The notification kind to evaluate.
    ///   - isPro:   Whether the user holds an active Pro entitlement.
    ///   - perKind: User's explicit per-kind override map.
    ///              Key = ``NotifKindKey`` raw-value string;
    ///              value = `true` (forward) or `false` (suppress).
    ///              When a kind has no entry, ``defaultForward(for:isPro:)`` applies.
    /// - Returns: `true` if the notification should be posted to Notification Center.
    public static func shouldForward(
        kind: NotifKindKey,
        isPro: Bool,
        perKind: [String: Bool]
    ) -> Bool {
        if let explicit = perKind[kind.rawValue] {
            Log.debug(
                "SystemNotificationPolicy: per-kind override",
                component: "SystemNotif",
                context: [("kind", kind.rawValue), ("forward", "\(explicit)")]
            )
            return explicit
        }
        let def = defaultForward(for: kind, isPro: isPro)
        Log.debug(
            "SystemNotificationPolicy: using default",
            component: "SystemNotif",
            context: [("kind", kind.rawValue), ("forward", "\(def)"), ("isPro", "\(isPro)")]
        )
        return def
    }

    /// Kinds considered "success" — gated off system delivery when the user turns
    /// off "notify on completion" (`notifyOnSuccess == false`).
    static let successKinds: Set<NotifKindKey> = [.newEpisode, .runFinished]

    /// Full system-forward decision, layering the user's notification preferences
    /// on top of the per-kind/Pro base. Each layer can only **suppress** (never
    /// force on). In-app notifications are unaffected — only Notification Center
    /// delivery is filtered.
    ///
    /// Layers (short-circuit on first suppression):
    /// 1. per-kind override / Pro default (``shouldForward(kind:isPro:perKind:)``)
    /// 2. on-success gate — `notifyOnSuccess == false` suppresses ``successKinds``
    /// 3. media-type filter — item's `mediaType` ∉ `notifyMediaTypes` (nil ⇒ fail-open)
    /// 4. quiet hours — `now` within `[quietStart, quietEnd]` (wrap-midnight aware)
    public static func shouldForwardToSystem(
        kind: NotifKindKey,
        isPro: Bool,
        perKind: [String: Bool],
        notifyOnSuccess: Bool,
        notifyMediaTypes: [String],
        mediaType: String?,
        quietHoursEnabled: Bool,
        quietStart: String,
        quietEnd: String,
        now: Date
    ) -> Bool {
        guard shouldForward(kind: kind, isPro: isPro, perKind: perKind) else { return false }

        if !notifyOnSuccess, successKinds.contains(kind) {
            Log.debug("SystemNotificationPolicy: suppressed by on-success",
                      component: "SystemNotif", context: [("kind", kind.rawValue)])
            return false
        }

        if let mediaType, !notifyMediaTypes.contains(mediaType) {
            Log.debug("SystemNotificationPolicy: suppressed by media-type filter",
                      component: "SystemNotif", context: [("kind", kind.rawValue), ("mediaType", mediaType)])
            return false
        }

        if quietHoursEnabled, isWithinQuietHours(now: now, start: quietStart, end: quietEnd) {
            Log.debug("SystemNotificationPolicy: suppressed by quiet hours",
                      component: "SystemNotif", context: [("kind", kind.rawValue), ("start", quietStart), ("end", quietEnd)])
            return false
        }

        return true
    }

    /// Whether `now`'s local wall-clock time falls within the `[start, end]`
    /// quiet-hours window. `HH:mm` strings; a `start > end` window wraps midnight
    /// (e.g. `22:00`–`08:00`). A zero-length window (`start == end`) is never active.
    /// Unparseable bounds ⇒ `false` (fail-open).
    public static func isWithinQuietHours(now: Date, start: String, end: String) -> Bool {
        guard let s = minutesOfDay(start), let e = minutesOfDay(end), s != e else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        guard let h = comps.hour, let m = comps.minute else { return false }
        let cur = h * 60 + m
        if s < e { return cur >= s && cur < e }      // same-day window
        return cur >= s || cur < e                    // wraps midnight
    }

    private static func minutesOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Default forwarding decision when the user has set no explicit override.
    ///
    /// - `.dailySummary` defaults to `true` for everyone (its emission is already
    ///    Free — product-owner clarification: the only Free↔Pro difference is
    ///    automatic transcription — so the default no longer keys on `isPro`).
    ///    All other kinds default to `false`.
    /// - Parameters:
    ///   - kind:  The notification kind to evaluate.
    ///   - isPro: Whether the user holds an active Pro entitlement. Kept for
    ///            signature stability / future kinds — no current case reads it.
    public static func defaultForward(for kind: NotifKindKey, isPro: Bool) -> Bool {
        switch kind {
        case .dailySummary:
            // Everyone gets a daily summary in Notification Center by default.
            return true
        case .modelReady:
            // "Model downloaded" is a wait-worth event → deliver to the system by
            // default (the user kicked off a multi-GB download and walked away).
            return true
        case .storageWarning, .mediaEvicted:
            // Storage is a "you might want to know even if the app isn't open"
            // event — forward to the system by default (per the media-retention brief).
            return true
        case .accountSuspended, .accountReauth,
             .keywordHit, .runFinished, .backfillDone,
             .failure, .newEpisode,
             .skippedNoSpeech:
            // Everything else is in-app only by default.
            // skippedNoSpeech is informational — in-app only unless the user opts in.
            return false
        }
    }
}
