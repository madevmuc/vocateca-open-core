import Foundation
import Security

// MARK: - AppDataResetReport

/// Summary of a ``AppDataReset/wipeEverything(userDataDir:logURL:keychainServices:clearKeychainService:)``
/// run — how much was actually removed/cleared, plus any (non-fatal) failures.
public struct AppDataResetReport: Sendable, Equatable {
    public var filesRemoved: Int
    public var keychainServicesCleared: Int
    public var errors: [String]

    public init(filesRemoved: Int = 0, keychainServicesCleared: Int = 0, errors: [String] = []) {
        self.filesRemoved = filesRemoved
        self.keychainServicesCleared = keychainServicesCleared
        self.errors = errors
    }
}

// MARK: - AppDataReset

/// Factory-reset: wipes ALL on-disk Vocateca data + the Keychain services it
/// owns. This is a DESTRUCTIVE, irreversible operation — callers must only
/// invoke it after an explicit, typed user confirmation (see the "Danger
/// zone" card in Settings).
///
/// Every removal is best-effort: a missing file, a locked file, or a Keychain
/// item that isn't there is NOT an error — it's simply skipped and logged.
/// The only way this reports an "error" is if a `FileManager` removal throws
/// for a reason other than "file not found" (e.g. a permissions problem);
/// even then, the function keeps going and finishes the rest of the wipe.
public enum AppDataReset {

    /// Removes every on-disk data file + the media tree + the logs file, then
    /// clears each provided Keychain service. Never throws — the caller
    /// receives a report describing what happened.
    ///
    /// - Parameters:
    ///   - userDataDir: The Vocateca user-data directory. Defaults to
    ///     ``Paths/userDataDir(fileManager:)``. Tests pass a temp directory so
    ///     real user data is never touched.
    ///   - logURL: The on-disk log file to remove. Defaults to the same
    ///     location `LogStore`'s production initializer writes to
    ///     (`~/Library/Caches/Vocateca/logs/vocateca.log`), recomputed here
    ///     because `LogStore` does not expose a static accessor for it.
    ///   - keychainServices: The Keychain service identifiers owned by
    ///     Vocateca. Defaults to Instagram + Integrations + Webhooks.
    ///   - clearKeychainService: Injectable so tests can pass a no-op/recording
    ///     stub instead of touching the real Keychain. Defaults to
    ///     ``defaultKeychainClear(service:)``.
    @discardableResult
    public static func wipeEverything(
        userDataDir: URL = Paths.userDataDir(),
        logURL: URL = defaultLogURL(),
        keychainServices: [String] = [
            "com.vocateca.instagram",
            "com.vocateca.integrations",
            "com.vocateca.webhooks",
        ],
        clearKeychainService: (String) -> Void = AppDataReset.defaultKeychainClear
    ) -> AppDataResetReport {
        let fm = FileManager.default
        var filesRemoved = 0
        var errors: [String] = []

        let dataFiles = [
            "state.sqlite", "state.sqlite-wal", "state.sqlite-shm",
            "notifications.sqlite", "notifications.sqlite-wal", "notifications.sqlite-shm",
            "settings.yaml", "watchlist.yaml",
        ]

        for name in dataFiles {
            let url = userDataDir.appendingPathComponent(name)
            if removeBestEffort(url, fileManager: fm, errors: &errors) {
                filesRemoved += 1
            }
        }

        // Media tree (recursive).
        let mediaDir = userDataDir.appendingPathComponent("media", isDirectory: true)
        if removeBestEffort(mediaDir, fileManager: fm, errors: &errors) {
            filesRemoved += 1
        }

        // „Zuletzt gelöscht" trash tree (recursive). The `trash_items` /
        // `trash_pending_media` tables live inside `state.sqlite` (removed above),
        // but the parked transcript files under `<userDataDir>/trash/` are separate
        // and must be erased here too, or a factory reset would leave user content
        // behind.
        let trashDir = userDataDir.appendingPathComponent("trash", isDirectory: true)
        if removeBestEffort(trashDir, fileManager: fm, errors: &errors) {
            filesRemoved += 1
        }

        // Logs file.
        if removeBestEffort(logURL, fileManager: fm, errors: &errors) {
            filesRemoved += 1
        }

        // Keychain services — best-effort, injectable.
        for service in keychainServices {
            clearKeychainService(service)
        }

        Log.info(
            "AppDataReset: wipeEverything completed",
            component: "AppDataReset",
            context: [
                ("filesRemoved", "\(filesRemoved)"),
                ("keychainServicesCleared", "\(keychainServices.count)"),
                ("errors", "\(errors.count)"),
            ]
        )

        return AppDataResetReport(
            filesRemoved: filesRemoved,
            keychainServicesCleared: keychainServices.count,
            errors: errors
        )
    }

    /// Removes `url` (file or directory) if present. Returns `true` when
    /// something was actually removed. A missing item is not an error and
    /// returns `false` silently; any other failure is appended to `errors`
    /// but does not stop the overall wipe.
    private static func removeBestEffort(
        _ url: URL,
        fileManager: FileManager,
        errors: inout [String]
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            try fileManager.removeItem(at: url)
            Log.info("AppDataReset: removed", component: "AppDataReset",
                     context: [("path", url.lastPathComponent)])
            return true
        } catch {
            let message = "Failed to remove \(url.lastPathComponent): \(error.localizedDescription)"
            Log.warn(message, component: "AppDataReset")
            errors.append(message)
            return false
        }
    }

    /// The production log file location — mirrors `LogStore`'s own
    /// production `init()` (`Logging.swift`), recomputed here because
    /// `LogStore` does not expose a static accessor for its default URL.
    public static func defaultLogURL(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Vocateca/logs/vocateca.log")
    }

    /// Default Keychain clear: deletes every generic-password item under
    /// `service`, regardless of account. Best-effort — `errSecItemNotFound`
    /// (nothing to delete) is expected and not logged as a failure.
    public static func defaultKeychainClear(service: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            Log.info("AppDataReset: cleared Keychain service", component: "AppDataReset",
                     context: [("service", service)])
        default:
            Log.warn("AppDataReset: Keychain clear returned unexpected status",
                      component: "AppDataReset",
                      context: [("service", service), ("status", "\(status)")])
        }
    }
}
