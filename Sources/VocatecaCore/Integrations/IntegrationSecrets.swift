import Foundation

/// Keychain-backed storage for integration credentials (kept out of settings.yaml).
public struct IntegrationSecrets: Sendable {
    public static let service = "com.vocateca.integrations"
    private static let notionAccount = "notion.token"
    private let store: KeychainStore
    public init(store: KeychainStore = SystemKeychainStore(service: IntegrationSecrets.service)) {
        self.store = store
    }
    public func notionToken() throws -> String? {
        guard let data = try store.get(account: Self.notionAccount) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    public func setNotionToken(_ token: String) throws {
        try store.set(Data(token.utf8), account: Self.notionAccount)
    }
    public func clearNotionToken() throws { try store.delete(account: Self.notionAccount) }
}
