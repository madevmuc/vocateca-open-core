import XCTest
@testable import VocatecaCore

// MARK: - PipelineEventEmitterTests
//
// L3 — event-emission ordering. The emitter must deliver events to the bus in the
// exact order `emit(_:)` was called, so a subscriber never sees progress fractions
// out of order (the old per-event `Task { await bus.emit }` had no such guarantee).

final class PipelineEventEmitterTests: XCTestCase {

    /// Emitting a long ascending sequence must arrive at the bus strictly in order.
    func testEventsArriveInEmissionOrder() async throws {
        let bus = EventBus()
        // Subscribe BEFORE emitting so every event is observed.
        let stream = await bus.subscribe(.exact(EventType.episodeProgress))

        let emitter = PipelineEventEmitter(bus: bus)
        let count = 200
        for i in 0..<count {
            emitter.emit(Event(
                type: EventType.episodeProgress,
                guid: "g",
                payload: ["fraction": .number(Double(i))]))
        }
        emitter.finish()   // close the channel so the consumer drains + the stream ends

        // Collect from the bus; the consumer forwards in FIFO order.
        var received: [Double] = []
        let collector = Task { () -> [Double] in
            var acc: [Double] = []
            for await ev in stream {
                if case .number(let f) = ev.payload["fraction"] { acc.append(f) }
                if acc.count == count { break }
            }
            return acc
        }
        received = try await withThrowingTaskGroup(of: [Double].self) { group in
            group.addTask { await collector.value }
            // Safety timeout so a regression can't hang the suite.
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                collector.cancel()
                return []
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertEqual(received.count, count, "every emitted event must reach the bus")
        XCTAssertEqual(received, received.sorted(),
                       "events must arrive in strictly non-decreasing (emission) order")
        XCTAssertEqual(received.first, 0)
        XCTAssertEqual(received.last, Double(count - 1))
    }

    /// A pipeline built with `bus: nil` emits nothing (unchanged behaviour): the
    /// emitter is absent, the emit paths are no-ops, and the episode still runs to
    /// `.done` purely via DB writes.
    func testNilBusStillCompletesEpisode() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "nobus")
        try store.upsert(ep)

        let pipeline = Pipeline(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/nobus.mp3"))),
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/nobus.md")),
            bus: nil)

        let result = await pipeline.process(ep)
        XCTAssertEqual(result.finalStatus, .done,
                       "a bus-less pipeline must still complete an episode (events are optional)")
    }
}
