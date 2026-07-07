import Foundation

/// A named, ready-to-use webhook configuration a user can pick from the
/// Settings UI (target left blank — the user pastes their own URL).
public struct WebhookPreset: Sendable {
    public let name: String
    public let entry: WebhookEntry
}

public enum WebhookPresets {
    public static let all: [WebhookPreset] = [
        WebhookPreset(name: "Slack",   entry: WebhookEntry(events: defaultEvents, kind: "command", target: "", enabled: true, secret: "", format: "slack")),
        WebhookPreset(name: "Discord", entry: WebhookEntry(events: defaultEvents, kind: "command", target: "", enabled: true, secret: "", format: "discord")),
        WebhookPreset(name: "n8n",     entry: WebhookEntry(events: defaultEvents, kind: "command", target: "", enabled: true, secret: "", format: "raw")),
    ]

    static let defaultEvents = ["episode.transcribed", "run.finished", "episode.failed"]
}
