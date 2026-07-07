import XCTest
import GRDB
@testable import VocatecaCore

// MARK: - JobHeartbeatReclaimTests
//
// H7 — App + CLI parallel reclaim must NOT kill an episode a live sibling process
// is actively working on. The guard uses the `jobs` ownership ledger: an in-flight
// row with an open job whose PID is a different, still-alive process AND whose
// heartbeat is fresh is left alone; everything else (no job, dead PID, stale
// heartbeat, our own leftover PID) is reclaimed exactly as before.

final class JobHeartbeatReclaimTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobHeartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(databaseURL: dir.appendingPathComponent("t.sqlite")), dir)
    }

    private func ep(_ guid: String, _ status: String) -> Episode {
        Episode(guid: guid, showSlug: "s", title: guid, pubDate: "2026-01-01",
                mp3Url: "https://e/\(guid).mp3", status: status)
    }

    // Self PID used across tests — a value distinct from the sibling PIDs below.
    private let selfPID: Int32 = 999_001

    // MARK: - Live sibling is protected

    /// An in-flight episode owned by a DIFFERENT, still-alive process with a FRESH
    /// heartbeat must NOT be reclaimed (the core H7 fix: no double-transcription).
    func testLiveHeartbeatIsNotReclaimed() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("cli-live", "transcribing"))
        let siblingPID: Int32 = 424_242
        try store.beginJob(guid: "cli-live", pid: siblingPID)   // heartbeat = now

        // sibling is "alive"; heartbeat is fresh → skip.
        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { $0 == siblingPID })
        XCTAssertEqual(reset, 0, "a live sibling's in-flight episode must not be reclaimed")
        XCTAssertEqual(try store.episode(guid: "cli-live")?.status, "transcribing",
                       "status must stay in-flight")
        XCTAssertEqual(try store.episode(guid: "cli-live")?.attempts, 0,
                       "attempts must not be bumped for a protected episode")
    }

    // MARK: - Dead owner is reclaimed

    /// A job row whose owning PID is dead (crashed CLI) IS an orphan → reclaimed
    /// with the normal attempts bump.
    func testDeadPIDIsReclaimed() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("cli-crashed", "downloading"))
        try store.beginJob(guid: "cli-crashed", pid: 424_242)

        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { _ in false })     // owner is dead
        XCTAssertEqual(reset, 1, "a dead owner's episode is an orphan and must be reclaimed")
        let row = try XCTUnwrap(store.episode(guid: "cli-crashed"))
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.attempts, 1, "reclaim still bumps attempts (wave-1 poison-pill guard)")
    }

    // MARK: - Stale heartbeat is reclaimed even if PID alive

    /// A wedged process (PID still alive but heartbeat older than the stale window)
    /// must NOT pin the episode forever — a stale heartbeat is reclaimed.
    func testStaleHeartbeatIsReclaimedEvenIfAlive() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("wedged", "transcribing"))
        let siblingPID: Int32 = 424_242
        try store.beginJob(guid: "wedged", pid: siblingPID)

        // Reclaim with a 0 s stale window: any heartbeat age >= 0 counts as stale.
        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 0,
            isAlive: { $0 == siblingPID })   // alive, but heartbeat is "stale"
        XCTAssertEqual(reset, 1, "a stale heartbeat must be reclaimed even if the PID is alive")
        XCTAssertEqual(try store.episode(guid: "wedged")?.status, "pending")
    }

    // MARK: - Our own leftover PID is reclaimed

    /// A job row stamped with OUR OWN pid is a leftover from a prior run of this
    /// same process image (or a PID that got recycled to us) — never a live
    /// sibling, so it must be reclaimed. Otherwise a crash under our own PID would
    /// wedge the episode across relaunch.
    func testSelfPIDLeftoverIsReclaimed() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("mine", "transcribing"))
        try store.beginJob(guid: "mine", pid: selfPID)   // our own pid

        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { _ in true })   // even if "alive", it's OUR pid → reclaim
        XCTAssertEqual(reset, 1, "our own leftover job row must not protect the episode")
        XCTAssertEqual(try store.episode(guid: "mine")?.status, "pending")
    }

    // MARK: - No job row → unchanged legacy reclaim

    /// An in-flight episode with NO job row is reclaimed exactly as before H7 —
    /// the guard adds protection, it never blocks a genuinely orphaned row.
    func testNoJobRowReclaimsAsBefore() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("orphan", "downloading"))     // no beginJob at all

        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { _ in true })
        XCTAssertEqual(reset, 1, "an un-owned in-flight row is reclaimed as before")
        XCTAssertEqual(try store.episode(guid: "orphan")?.status, "pending")
    }

    // MARK: - endJob releases the guard

    /// After the owner closes its job (`endJob`), the episode is no longer
    /// protected — a subsequent reclaim treats it as orphaned.
    func testEndJobReleasesProtection() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("finished-job", "transcribing"))
        let siblingPID: Int32 = 424_242
        try store.beginJob(guid: "finished-job", pid: siblingPID)
        try store.endJob(guid: "finished-job", pid: siblingPID)   // owner done

        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { $0 == siblingPID })   // still "alive" but job is closed
        XCTAssertEqual(reset, 1, "a closed job must not protect the episode")
        XCTAssertEqual(try store.episode(guid: "finished-job")?.status, "pending")
    }

    // MARK: - Mixed batch: protect only the live one

    /// One live-owned + one orphaned in-flight episode: only the orphan is reclaimed.
    func testMixedBatchProtectsOnlyLiveOwner() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("live", "transcribing"))
        try store.upsert(ep("orphan", "downloading"))
        let siblingPID: Int32 = 424_242
        try store.beginJob(guid: "live", pid: siblingPID)   // orphan has no job

        let reset = try store.reclaimOrphanedInFlight(
            selfPID: selfPID,
            staleSeconds: 600,
            isAlive: { $0 == siblingPID })
        XCTAssertEqual(reset, 1, "only the un-owned episode is reclaimed")
        XCTAssertEqual(try store.episode(guid: "live")?.status, "transcribing")
        XCTAssertEqual(try store.episode(guid: "orphan")?.status, "pending")
    }

    // MARK: - Pipeline integration: a full run opens then closes a job row

    /// Driving one episode through the real `Pipeline` must open a job row while
    /// working and close it (`ended_at` set) at the terminal status — so a
    /// concurrent reclaim sees it as owned mid-run and un-owned afterwards.
    func testPipelineOpensAndClosesJobRow() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let episode = Episode.makePodcast(guid: "pipe-job")
        try store.upsert(episode)

        let pipeline = Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/pipe-job.mp3"))),
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/pipe-job.md")),
            bus: nil)

        let result = await pipeline.process(episode)
        XCTAssertEqual(result.finalStatus, .done)

        // Exactly one job row was written for this guid, and it is now CLOSED.
        let (total, open) = try await store.dbQueue.read { db -> (Int, Int) in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE guid = ?",
                                         arguments: ["pipe-job"]) ?? -1
            let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE guid = ? AND ended_at IS NULL",
                                        arguments: ["pipe-job"]) ?? -1
            return (total, open)
        }
        XCTAssertEqual(total, 1, "the pipeline must open exactly one job row for the episode")
        XCTAssertEqual(open, 0, "the job row must be closed (ended_at set) at the terminal status")
    }

    // MARK: - processIsAlive probe sanity

    /// The real liveness probe reports this very process as alive and an
    /// impossible PID as dead.
    func testProcessIsAliveProbe() {
        let mypid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(processIsAlive(mypid), "the current process must read as alive")
        XCTAssertFalse(processIsAlive(0), "pid 0 is never a reclaimable owner")
        XCTAssertFalse(processIsAlive(Int32.max - 1), "an impossible PID must read as dead")
    }
}
