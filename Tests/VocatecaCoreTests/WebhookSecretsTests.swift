import XCTest
@testable import VocatecaCore

/// Tests for ``WebhookSecrets`` and ``WebhookSecretsMigration``.
///
/// Uses ``InMemoryKeychainStore`` — never touches the real macOS Keychain.
final class WebhookSecretsTests: XCTestCase {

    // MARK: - WebhookSecrets round-trip

    func testSetGetDeleteRoundTrips() throws {
        let s = WebhookSecrets(store: InMemoryKeychainStore())
        try s.setSecret("shh", id: "wh1")
        XCTAssertEqual(try s.secret(id: "wh1"), "shh")
        try s.deleteSecret(id: "wh1")
        XCTAssertNil(try s.secret(id: "wh1"))
    }

    func testMissingSecretReturnsNil() throws {
        let s = WebhookSecrets(store: InMemoryKeychainStore())
        XCTAssertNil(try s.secret(id: "does-not-exist"))
    }

    func testMultipleWebhookIdsAreIndependent() throws {
        let s = WebhookSecrets(store: InMemoryKeychainStore())
        try s.setSecret("secret-1", id: "wh1")
        try s.setSecret("secret-2", id: "wh2")
        XCTAssertEqual(try s.secret(id: "wh1"), "secret-1")
        XCTAssertEqual(try s.secret(id: "wh2"), "secret-2")
    }

    // MARK: - Migration

    func testMigrationMovesPlaintextSecretsToKeychainAndBlanksSettings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebhookSecretsMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appendingPathComponent("settings.yaml")

        var settings = Settings()
        let entry = WebhookEntry(target: "https://example.com/hook", id: "wh1", secret: "abc")
        settings.webhooks = [entry]
        try SettingsStore.save(settings, to: settingsURL)

        let keychain = InMemoryKeychainStore()
        let secrets = WebhookSecrets(store: keychain)

        let migrated = WebhookSecretsMigration.run(settingsURL: settingsURL, secrets: secrets)
        XCTAssertEqual(migrated, 1)

        // Keychain now holds the secret, keyed by webhook id.
        XCTAssertEqual(try secrets.secret(id: "wh1"), "abc")

        // settings.yaml on disk has the field blanked.
        let reloaded = try SettingsStore.load(from: settingsURL, persistDefaultOnMissing: false)
        XCTAssertEqual(reloaded.webhooks.first?.secret, "")

        // Idempotent: a second run migrates nothing further.
        let secondRun = WebhookSecretsMigration.run(settingsURL: settingsURL, secrets: secrets)
        XCTAssertEqual(secondRun, 0)
    }

    func testMigrationSkipsAlreadyBlankSecrets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebhookSecretsMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appendingPathComponent("settings.yaml")

        var settings = Settings()
        settings.webhooks = [WebhookEntry(target: "https://example.com/hook", id: "wh1", secret: "")]
        try SettingsStore.save(settings, to: settingsURL)

        let migrated = WebhookSecretsMigration.run(
            settingsURL: settingsURL,
            secrets: WebhookSecrets(store: InMemoryKeychainStore())
        )
        XCTAssertEqual(migrated, 0)
    }
}
