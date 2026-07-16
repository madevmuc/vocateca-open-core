import XCTest
import Foundation
@testable import VocatecaCore

/// Guards the backoff deadlock (2026-07-16): a show in backoff could never be
/// polled again, because the ONLY thing that clears a backoff is a successful
/// poll — and no poll could run while the backoff held. Subscribing, Repair's
/// retry and the episode list's "Try again" were all silent no-ops for 1–7 days,
/// against a feed that was answering HTTP 200 the whole time.
final class FeedBackoffForceTests: XCTestCase {

    private func makeTempStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedBackoffForce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(databaseURL: dir.appendingPathComponent("t.sqlite")), dir)
    }

    /// Drives a show into backoff the way production does: three consecutive
    /// failures (`FeedBackoff.threshold`).
    private func driveIntoBackoff(slug: String, store: StateStore) throws {
        for _ in 0..<FeedBackoff.threshold {
            _ = try FeedBackoff.onFailure(showSlug: slug, store: store)
        }
        XCTAssertTrue(try FeedBackoff.inBackoff(showSlug: slug, store: store),
                      "precondition: the show must actually be in backoff")
    }

    private func makeShow(_ slug: String) -> Show {
        // An unreachable host: the poll must FAIL, not hang. What this test cares
        // about is whether the backoff check lets us get that far at all.
        Show(slug: slug, title: slug,
             rss: "https://invalid.invalid/feed.xml", source: "podcast")
    }

    // MARK: - The deadlock

    /// Without `force`, a backed-off show is refused before any fetch is attempted
    /// — this is correct for the automatic poller and must stay.
    func testAutomaticPollIsStillRefusedWhileInBackoff() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try driveIntoBackoff(slug: "s", store: store)

        do {
            _ = try await FeedIngestor().poll(show: makeShow("s"), store: store)
            XCTFail("expected .inBackoff")
        } catch let error as FeedIngestorError {
            guard case .inBackoff = error else {
                return XCTFail("expected .inBackoff, got \(error)")
            }
        }
    }

    /// With `force`, the same show gets past the gate. It still fails here — the
    /// host is unreachable — but it fails as a FETCH, not as `.inBackoff`, which
    /// is the whole point: the user's button press reached the network.
    func testForcedPollBypassesBackoff() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try driveIntoBackoff(slug: "s", store: store)

        do {
            _ = try await FeedIngestor().poll(show: makeShow("s"), store: store, force: true)
            XCTFail("expected a fetch failure against an unreachable host")
        } catch let error as FeedIngestorError {
            if case .inBackoff = error {
                XCTFail("force must bypass the backoff — this is the deadlock")
            }
            // Any other FeedIngestorError (fetchFailed) means we got past the gate.
        }
    }

    /// `force` must not disarm the guard for everyone else: after a forced poll
    /// fails, the automatic path is still refused.
    func testForcedPollDoesNotClearBackoffForAutomaticCallers() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try driveIntoBackoff(slug: "s", store: store)

        _ = try? await FeedIngestor().poll(show: makeShow("s"), store: store, force: true)

        XCTAssertTrue(try FeedBackoff.inBackoff(showSlug: "s", store: store),
                      "a failed forced poll must leave the backoff armed")
        do {
            _ = try await FeedIngestor().poll(show: makeShow("s"), store: store)
            XCTFail("expected .inBackoff for the automatic caller")
        } catch let error as FeedIngestorError {
            guard case .inBackoff = error else {
                return XCTFail("expected .inBackoff, got \(error)")
            }
        }
    }

    /// The escape hatch that makes `force` self-correcting: a SUCCESSFUL poll
    /// clears the backoff through the normal `onSuccess` path, so the automatic
    /// poller resumes on its own. Simulated here at the FeedBackoff layer, since
    /// a real success needs a live feed.
    func testSuccessClearsBackoffSoAutomaticPollingResumes() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try driveIntoBackoff(slug: "s", store: store)

        try FeedBackoff.onSuccess(showSlug: "s", store: store)

        XCTAssertFalse(try FeedBackoff.inBackoff(showSlug: "s", store: store))
    }

    /// A disabled show is refused even when forced — `force` overrides the
    /// backoff, not the user's own "pause this show" decision.
    func testForceDoesNotOverrideDisabledShow() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var show = makeShow("s")
        show.enabled = false
        do {
            _ = try await FeedIngestor().poll(show: show, store: store, force: true)
            XCTFail("expected .showDisabled")
        } catch let error as FeedIngestorError {
            guard case .showDisabled = error else {
                return XCTFail("expected .showDisabled, got \(error)")
            }
        }
    }
}
