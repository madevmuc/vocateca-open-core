import Foundation

/// One-time (idempotent) migration that moves plaintext webhook HMAC secrets
/// out of `settings.yaml` and into the Keychain via ``WebhookSecrets``.
///
/// Safe to call on every launch: entries whose `.secret` is already blank
/// (either never set, or already migrated) are skipped, so a second run
/// always migrates 0.
public enum WebhookSecretsMigration {

    /// Loads ``Settings`` from `settingsURL`, moves every non-empty
    /// `webhooks[i].secret` into the Keychain (account = the webhook's stable
    /// `id`), blanks the field, and — if anything was migrated — saves
    /// `Settings` back to `settingsURL`.
    ///
    /// Best-effort: never throws. A failure to read/write the Keychain for a
    /// given entry just leaves that entry's plaintext secret in place (it will
    /// be retried on the next launch); a failure to load/save `settings.yaml`
    /// is logged and aborts the migration for this run.
    @discardableResult
    public static func run(settingsURL: URL, secrets: WebhookSecrets) -> Int {
        guard var settings = try? SettingsStore.load(from: settingsURL, persistDefaultOnMissing: false) else {
            return 0
        }

        var migratedCount = 0
        for i in settings.webhooks.indices {
            let entry = settings.webhooks[i]
            guard !entry.secret.isEmpty else { continue }
            do {
                try secrets.setSecret(entry.secret, id: entry.id)
                settings.webhooks[i].secret = ""
                migratedCount += 1
            } catch {
                Log.warn("WebhookSecretsMigration: failed to migrate secret",
                         component: "Privacy",
                         context: [("id", entry.id), ("error", "\(error)")])
            }
        }

        if migratedCount > 0 {
            do {
                try SettingsStore.save(settings, to: settingsURL)
            } catch {
                Log.warn("WebhookSecretsMigration: failed to save settings after migration",
                         component: "Privacy",
                         context: [("error", "\(error)")])
                return migratedCount
            }
            Log.info("WebhookSecretsMigration: migrated \(migratedCount) secrets to Keychain",
                     component: "Privacy",
                     context: [("count", "\(migratedCount)")])
        }

        return migratedCount
    }
}
