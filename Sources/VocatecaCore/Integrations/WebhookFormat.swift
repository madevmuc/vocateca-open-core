import Foundation

/// Reshapes an ``Event`` into the body a webhook endpoint expects, based on
/// its `WebhookEntry.format` ("raw" | "slack" | "discord").
///
/// Pure Foundation, no I/O — fully unit-testable.
///
/// ## Raw path — this is a FALLBACK, not the production raw path
///
/// The real, production "raw" delivery is `Webhooks.jsonBody(for:deliveryID:occurredAt:)`
/// (see `VocatecaCore/Webhooks/WebhookPayload.swift`), which builds a signed
/// envelope carrying delivery metadata (`id`, `occurredAt`) that only the
/// dispatcher has at send time. `WebhookDispatcher` therefore calls
/// `Webhooks.jsonBody` directly for the raw case and routes only `"slack"` /
/// `"discord"` through `WebhookFormat.body(for:format:)`, so existing webhook
/// entries keep receiving a byte-identical body to before this feature.
///
/// `WebhookFormat`'s own `"raw"`/unknown branch exists so this type is
/// self-contained and testable without delivery metadata: it returns a
/// simple event-envelope JSON built from the event alone
/// (`{"type":…, "show_slug":…, "guid":…, "payload":…}`). Any caller that
/// only has an `Event` (no delivery id) — or an unrecognized format string —
/// gets this fallback.
public enum WebhookFormat {
    public static func body(for event: Event, format: String) -> Data {
        switch format {
        case "slack":   return json(["text": summary(event: event)])
        case "discord": return json(["content": summary(event: event)])
        default:        return rawBody(for: event)      // "raw" + any unknown
        }
    }

    static func summary(event: Event) -> String {
        let title = event.payload["title"].flatMap(stringValue) ?? event.guid ?? ""
        return "vocateca — \(event.type)\(title.isEmpty ? "" : ": \(title)")"
    }

    /// Self-contained fallback envelope, built from the event alone (no
    /// delivery metadata). NOT used by `WebhookDispatcher`'s real raw path —
    /// see the type-level doc comment.
    static func rawBody(for event: Event) -> Data {
        var obj: [String: Any] = ["type": event.type]
        obj["show_slug"] = event.showSlug
        obj["guid"] = event.guid
        obj["payload"] = jsonObject(from: event.payload)
        return json(obj)
    }

    private static func jsonObject(from payload: [String: JSONValue]) -> [String: Any] {
        payload.mapValues(jsonAny)
    }

    private static func jsonAny(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s):  return s
        case .number(let n):  return n
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let a):   return a.map(jsonAny)
        case .object(let o):  return o.mapValues(jsonAny)
        }
    }

    private static func json(_ o: [String: Any]) -> Data {
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: o, options: options)) ?? Data("{}".utf8)
    }

    private static func stringValue(_ v: JSONValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }
}
