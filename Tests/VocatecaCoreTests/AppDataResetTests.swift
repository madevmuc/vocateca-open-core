import XCTest
@testable import VocatecaCore

final class AppDataResetTests: XCTestCase {

    /// Builds a temp `userDataDir` populated with fake data files + a media
    /// tree, and a separate temp log file. Never touches real user data.
    private func makeFixture() throws -> (userDataDir: URL, logURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDataResetTests-\(UUID().uuidString)", isDirectory: true)
        let userDataDir = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)

        // Fake data files.
        try Data("fake-state".utf8).write(to: userDataDir.appendingPathComponent("state.sqlite"))
        try Data("fake-wal".utf8).write(to: userDataDir.appendingPathComponent("state.sqlite-wal"))
        try Data("fake-shm".utf8).write(to: userDataDir.appendingPathComponent("state.sqlite-shm"))
        try Data("fake-notifications".utf8).write(to: userDataDir.appendingPathComponent("notifications.sqlite"))
        try Data("settings: {}".utf8).write(to: userDataDir.appendingPathComponent("settings.yaml"))
        try Data("shows: []".utf8).write(to: userDataDir.appendingPathComponent("watchlist.yaml"))

        // Media tree.
        let mediaShowDir = userDataDir.appendingPathComponent("media/show", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaShowDir, withIntermediateDirectories: true)
        try Data("fake-mp3".utf8).write(to: mediaShowDir.appendingPathComponent("ep.mp3"))

        // Temp log file (separate location, mirroring the real logs dir shape).
        let logDir = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("vocateca.log")
        try Data("log line 1\n".utf8).write(to: logURL)

        return (userDataDir, logURL)
    }

    func test_wipeEverything_removesAllFilesAndClearsKeychainServices() throws {
        let (userDataDir, logURL) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: userDataDir.deletingLastPathComponent()) }

        var clearedServices: [String] = []
        let services = ["com.vocateca.instagram", "com.vocateca.integrations", "com.vocateca.webhooks"]

        let report = AppDataReset.wipeEverything(
            userDataDir: userDataDir,
            logURL: logURL,
            keychainServices: services,
            clearKeychainService: { service in clearedServices.append(service) }
        )

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("state.sqlite").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("state.sqlite-wal").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("state.sqlite-shm").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("notifications.sqlite").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("settings.yaml").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("watchlist.yaml").path))
        XCTAssertFalse(fm.fileExists(atPath: userDataDir.appendingPathComponent("media").path))
        XCTAssertFalse(fm.fileExists(atPath: logURL.path))

        XCTAssertEqual(clearedServices, services)
        XCTAssertEqual(report.keychainServicesCleared, services.count)
        XCTAssertGreaterThanOrEqual(report.filesRemoved, 7)
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    func test_wipeEverything_secondRunOnEmptyDir_doesNotThrowAndReportsNoErrors() throws {
        let (userDataDir, logURL) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: userDataDir.deletingLastPathComponent()) }

        var clearedCount = 0
        let services = ["com.vocateca.instagram", "com.vocateca.integrations", "com.vocateca.webhooks"]

        // First run empties everything out.
        _ = AppDataReset.wipeEverything(
            userDataDir: userDataDir,
            logURL: logURL,
            keychainServices: services,
            clearKeychainService: { _ in clearedCount += 1 }
        )
        clearedCount = 0

        // Second run: nothing left on disk. Must not throw and must report 0 errors.
        let report = AppDataReset.wipeEverything(
            userDataDir: userDataDir,
            logURL: logURL,
            keychainServices: services,
            clearKeychainService: { _ in clearedCount += 1 }
        )

        XCTAssertEqual(report.errors.count, 0)
        XCTAssertEqual(report.filesRemoved, 0)
        XCTAssertEqual(clearedCount, services.count)
    }
}
