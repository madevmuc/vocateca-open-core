import Foundation
import Security

// MARK: - Protocol

/// Abstraction over a Keychain-backed (or in-memory) credential store.
///
/// Cookies / account tokens are stored as `Data` blobs keyed by `account_id`
/// (the Instagram account identifier string).  No secrets are hardcoded.
///
/// The protocol is `Sendable` so implementations can be passed across actor
/// boundaries and stored in actors / classes without data-race warnings.
public protocol KeychainStore: Sendable {
    /// Stores `value` under `account`.  Overwrites any existing entry.
    func set(_ value: Data, account: String) throws

    /// Returns the stored blob for `account`, or `nil` when absent.
    func get(account: String) throws -> Data?

    /// Deletes the entry for `account`.  No-op if the entry does not exist.
    func delete(account: String) throws
}

// MARK: - KeychainError

/// Errors surfaced by `SystemKeychainStore`.
public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case unexpectedDataFormat
}

// MARK: - SystemKeychainStore

/// A `KeychainStore` backed by the macOS Security framework (`SecItem*` APIs).
///
/// All items are stored under the service name `"com.vocateca.instagram"`.
/// The `account` parameter maps to `kSecAttrAccount`.
///
/// **Do not use in unit tests** — this touches the real macOS login Keychain.
/// Use `InMemoryKeychainStore` instead (inject via protocol).
public struct SystemKeychainStore: KeychainStore {

    /// Keychain service identifier used for all items managed by Vocateca.
    public static let service = "com.vocateca.instagram"

    /// The Keychain service identifier this instance stores items under.
    /// Defaults to ``service`` (Instagram) so existing call sites that use
    /// `SystemKeychainStore()` keep working unchanged.
    public let service: String

    public init(service: String = SystemKeychainStore.service) {
        self.service = service
    }

    // MARK: - KeychainStore

    public func set(_ value: Data, account: String) throws {
        // Delete any existing item first (update path is complex; delete + add is simpler
        // and equally atomic for our single-item-per-account use case). This also
        // ensures a pre-existing item created under an older (looser) accessibility
        // class gets re-created under the current, tighter class below.
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: account,
        ]
        let delStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard delStatus == errSecSuccess || delStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(delStatus)
        }

        // ThisDeviceOnly: the item is excluded from iCloud Keychain sync / device
        // backups, so an Instagram session cookie can never leave this Mac via a
        // backup or migration to another device.
        let addQuery: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     self.service,
            kSecAttrAccount:     account,
            kSecValueData:       value,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func get(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      self.service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedDataFormat
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - InMemoryKeychainStore

/// A thread-safe in-memory `KeychainStore` for use in tests.
///
/// Backed by a `[String: Data]` dictionary protected by `NSLock`.
/// Does NOT touch the real macOS Keychain.
///
/// `@unchecked Sendable` is safe here because all mutations are serialised
/// through `lock`.
public final class InMemoryKeychainStore: @unchecked Sendable, KeychainStore {

    private let lock = NSLock()
    private var _store: [String: Data] = [:]

    public init() {}

    public func set(_ value: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        _store[account] = value
    }

    public func get(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return _store[account]
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        _store.removeValue(forKey: account)
    }
}
