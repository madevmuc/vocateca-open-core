import XCTest
import Foundation
@testable import VocatecaCore

/// Integrations — Task 4: `IntegrationSender` orchestration (load episode +
/// transcript, call the injected Notion client, record a delivery marker).
/// No network — the Notion client is a fake injected via `notionFactory`.
final class IntegrationSenderTests: XCTestCase {

    // MARK: - Fakes

    final class FakeNotion: NotionPageCreating, @unchecked Sendable {
        var lastDatabaseId: String?
        var lastTitle: String?
        var lastBlocks: [String]?
        private(set) var createCount = 0
        var result: Result<String, Error> = .success("page_x")

        func createPage(databaseId: String, title: String, properties: [String: NotionValue], blocks: [String]) async throws -> String {
            createCount += 1
            lastDatabaseId = databaseId
            lastTitle = title
            lastBlocks = blocks
            return try result.get()
        }
    }

    struct StubSecrets: NotionTokenProviding {
        let token: String?
        func notionToken() throws -> String? { token }
    }

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationSenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    /// Inserts an episode with a transcript file on disk and returns the dir
    /// holding the transcript (caller owns cleanup alongside the store dir).
    @discardableResult
    private static func insertEpisode(
        _ store: StateStore,
        guid: String,
        title: String,
        transcript: String?
    ) throws -> URL? {
        var transcriptPath: String?
        var transcriptDir: URL?
        if let transcript {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("IntegrationSenderTests-transcript-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(guid).txt")
            try transcript.write(to: file, atomically: true, encoding: .utf8)
            transcriptPath = file.path
            transcriptDir = dir
        }
        let episode = Episode(
            guid: guid,
            showSlug: "show1",
            title: title,
            pubDate: "2026-01-01",
            mp3Url: "https://cdn.example.com/\(guid).mp3",
            status: "done",
            transcriptPath: transcriptPath
        )
        try store.dbQueue.write { db in try episode.insert(db) }
        return transcriptDir
    }

    private func settingsWith(databaseId: String) -> Settings {
        var s = Settings()
        s.notionDatabaseId = databaseId
        s.notionEnabled = true
        return s
    }

    // MARK: - 1. Happy path: loads episode, creates page, records delivery

    func testSendLoadsEpisodeCreatesPageAndRecordsDelivery() async throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriptDir = try Self.insertEpisode(store, guid: "g1", title: "Ep", transcript: "body text")
        defer { if let transcriptDir { try? FileManager.default.removeItem(at: transcriptDir) } }

        let fake = FakeNotion()
        let sender = IntegrationSender(notionFactory: { _ in fake })
        let outcome = await sender.send(episodeGuid: "g1", to: .notion,
                                         store: store, secrets: StubSecrets(token: "t"),
                                         settings: settingsWith(databaseId: "db1"))

        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(fake.lastDatabaseId, "db1")
        XCTAssertEqual(try store.lastDelivery(integration: "notion", episodeGuid: "g1")?.status, "ok")
    }

    // MARK: - 2. No token → failure, no page created

    func testSendWithoutTokenFails() async throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriptDir = try Self.insertEpisode(store, guid: "g1", title: "Ep", transcript: "x")
        defer { if let transcriptDir { try? FileManager.default.removeItem(at: transcriptDir) } }

        let fake = FakeNotion()
        let outcome = await IntegrationSender(notionFactory: { _ in fake })
            .send(episodeGuid: "g1", to: .notion, store: store,
                  secrets: StubSecrets(token: nil), settings: settingsWith(databaseId: "db1"))

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(fake.createCount, 0)
        XCTAssertEqual(try store.lastDelivery(integration: "notion", episodeGuid: "g1")?.status, "error")
    }

    // MARK: - 3. Idempotency: second send does not create a duplicate page

    func testSendIsIdempotent() async throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcriptDir = try Self.insertEpisode(store, guid: "g1", title: "Ep", transcript: "body text")
        defer { if let transcriptDir { try? FileManager.default.removeItem(at: transcriptDir) } }

        let fake = FakeNotion()
        let sender = IntegrationSender(notionFactory: { _ in fake })

        let first = await sender.send(episodeGuid: "g1", to: .notion, store: store,
                                       secrets: StubSecrets(token: "t"), settings: settingsWith(databaseId: "db1"))
        XCTAssertTrue(first.ok)
        XCTAssertEqual(fake.createCount, 1)

        let second = await sender.send(episodeGuid: "g1", to: .notion, store: store,
                                        secrets: StubSecrets(token: "t"), settings: settingsWith(databaseId: "db1"))
        XCTAssertTrue(second.ok)
        XCTAssertEqual(fake.createCount, 1, "Second send for the same guid must not create a duplicate page")
    }

    // MARK: - 4. Missing episode → error outcome, never crashes

    func testSendWithMissingEpisodeFails() async throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeNotion()
        let outcome = await IntegrationSender(notionFactory: { _ in fake })
            .send(episodeGuid: "does-not-exist", to: .notion, store: store,
                  secrets: StubSecrets(token: "t"), settings: settingsWith(databaseId: "db1"))

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(fake.createCount, 0)
    }

    // MARK: - 5. Missing transcript path → error outcome, never crashes

    func testSendWithMissingTranscriptFails() async throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.insertEpisode(store, guid: "g1", title: "Ep", transcript: nil)

        let fake = FakeNotion()
        let outcome = await IntegrationSender(notionFactory: { _ in fake })
            .send(episodeGuid: "g1", to: .notion, store: store,
                  secrets: StubSecrets(token: "t"), settings: settingsWith(databaseId: "db1"))

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(fake.createCount, 0)
        XCTAssertEqual(try store.lastDelivery(integration: "notion", episodeGuid: "g1")?.status, "error")
    }
}
