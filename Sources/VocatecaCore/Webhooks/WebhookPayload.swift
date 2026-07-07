import Foundation
import CryptoKit

/// Pure webhook helpers — payload building, HMAC signing, and event→endpoint
/// routing. No I/O and no entitlement logic (that lives in the Pro dispatcher),
/// so these are fully unit-testable.
public enum Webhooks {

    /// The delivered JSON envelope.
    struct Envelope: Encodable {
        let id: String
        let type: String
        let occurredAt: String
        let show: [String: String]?
        let episode: [String: String]?
        let data: [String: JSONValue]
    }

    /// Builds the signed-over JSON body for `event`. Deterministic (sorted keys)
    /// so the signature is stable and testable.
    public static func jsonBody(for event: Event, deliveryID: String, occurredAt: String) -> Data {
        let env = Envelope(
            id: deliveryID,
            type: event.type,
            occurredAt: occurredAt,
            show: event.showSlug.map { ["slug": $0] },
            episode: event.guid.map { ["guid": $0] },
            data: event.payload
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(env)) ?? Data("{}".utf8)
    }

    /// `sha256=<hex HMAC-SHA256(secret, body)>`. Empty secret still produces a
    /// (weak) signature; callers omit the header when the secret is empty.
    public static func signature(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Enabled endpoints subscribed to this event's type.
    public static func endpoints(matching event: Event, in webhooks: [WebhookEntry]) -> [WebhookEntry] {
        webhooks.filter { $0.enabled && $0.events.contains(event.type) }
    }
}
