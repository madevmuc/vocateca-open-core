import XCTest
@testable import VocatecaCore

/// Tests for ``KeychainStore`` protocol implementations.
///
/// All tests use ``InMemoryKeychainStore`` — they never touch the real macOS
/// login Keychain.  A ``SystemKeychainStore`` smoke test is available but is
/// gated behind the `VOCATECA_KEYCHAIN_TEST` environment variable so CI
/// does not accidentally write to the user's Keychain.
final class KeychainStoreTests: XCTestCase {

    // MARK: - InMemoryKeychainStore

    func testSetAndGet() throws {
        let store = InMemoryKeychainStore()
        let value = Data("cookie_value_abc".utf8)
        try store.set(value, account: "account-1")
        let retrieved = try store.get(account: "account-1")
        XCTAssertEqual(retrieved, value)
    }

    func testMissingKeyReturnsNil() throws {
        let store = InMemoryKeychainStore()
        let result = try store.get(account: "nonexistent")
        XCTAssertNil(result)
    }

    func testOverwrite() throws {
        let store = InMemoryKeychainStore()
        let first  = Data("first".utf8)
        let second = Data("second".utf8)
        try store.set(first,  account: "acc")
        try store.set(second, account: "acc")
        let result = try store.get(account: "acc")
        XCTAssertEqual(result, second, "Second set should overwrite first")
    }

    func testDelete() throws {
        let store = InMemoryKeychainStore()
        let value = Data("to_be_deleted".utf8)
        try store.set(value, account: "acc")
        try store.delete(account: "acc")
        let result = try store.get(account: "acc")
        XCTAssertNil(result, "After delete, get should return nil")
    }

    func testDeleteNonExistentIsNoOp() throws {
        let store = InMemoryKeychainStore()
        // Must not throw.
        XCTAssertNoThrow(try store.delete(account: "does-not-exist"))
    }

    func testMultipleAccounts() throws {
        let store = InMemoryKeychainStore()
        let d1 = Data("cookie-1".utf8)
        let d2 = Data("cookie-2".utf8)
        try store.set(d1, account: "acc-1")
        try store.set(d2, account: "acc-2")
        XCTAssertEqual(try store.get(account: "acc-1"), d1)
        XCTAssertEqual(try store.get(account: "acc-2"), d2)
    }

    func testEmptyDataRoundTrip() throws {
        let store = InMemoryKeychainStore()
        let empty = Data()
        try store.set(empty, account: "empty-acc")
        let retrieved = try store.get(account: "empty-acc")
        XCTAssertEqual(retrieved, empty)
    }

    func testDeleteRemovesOnlyTargetKey() throws {
        let store = InMemoryKeychainStore()
        try store.set(Data("a".utf8), account: "a")
        try store.set(Data("b".utf8), account: "b")
        try store.delete(account: "a")
        XCTAssertNil(try store.get(account: "a"))
        XCTAssertNotNil(try store.get(account: "b"), "Deleting 'a' must not affect 'b'")
    }

    func testBinaryDataRoundTrip() throws {
        let store = InMemoryKeychainStore()
        // Simulate a real cookie blob (arbitrary bytes).
        let binary = Data([0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0x42])
        try store.set(binary, account: "binary-acc")
        XCTAssertEqual(try store.get(account: "binary-acc"), binary)
    }

    // MARK: - SystemKeychainStore smoke test (CI-gated)

    /// Smoke test for the real Keychain. Only runs when the env var
    /// `VOCATECA_KEYCHAIN_TEST=1` is set to avoid polluting CI or
    /// the developer's actual Keychain during normal test runs.
    func testSystemKeychainStoreRoundTripIfEnabled() throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Set VOCATECA_KEYCHAIN_TEST=1 to run real Keychain test")
        }

        let store = SystemKeychainStore()
        let testAccount = "vocateca-test-\(UUID().uuidString)"
        let value = Data("test-cookie-\(UUID().uuidString)".utf8)

        defer {
            // Always clean up even if the test fails.
            try? store.delete(account: testAccount)
        }

        try store.set(value, account: testAccount)
        let retrieved = try store.get(account: testAccount)
        XCTAssertEqual(retrieved, value, "SystemKeychainStore set/get round-trip failed")

        try store.delete(account: testAccount)
        XCTAssertNil(try store.get(account: testAccount),
                     "After delete, get should return nil")
    }
}
