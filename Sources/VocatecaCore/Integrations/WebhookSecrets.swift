import Foundation

/// Keychain-backed storage for webhook HMAC signing secrets (kept out of
/// settings.yaml). Mirrors ``IntegrationSecrets`` but keyed by the webhook's
/// stable ``WebhookEntry/id`` rather than a fixed account name, since there
/// can be many webhook endpoints.
public struct WebhookSecrets: Sendable {
    public static let service = "com.vocateca.webhooks"
    private let store: KeychainStore
    public init(store: KeychainStore = SystemKeychainStore(service: WebhookSecrets.service)) {
        self.store = store
    }

    /// Returns the stored HMAC secret for the webhook `id`, or `nil` if none.
    public func secret(id: String) throws -> String? {
        guard let data = try store.get(account: id) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores `secret` under the webhook `id`, overwriting any existing value.
    public func setSecret(_ secret: String, id: String) throws {
        try store.set(Data(secret.utf8), account: id)
    }

    /// Deletes the stored secret for the webhook `id`. No-op if absent.
    public func deleteSecret(id: String) throws {
        try store.delete(account: id)
    }
}
