import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - MockURLProtocol

/// A deterministic `URLProtocol` subclass for injecting HTTP responses without
/// any real network activity.
///
/// Register handlers per URL string before the test, unregister after.
///
/// Usage:
/// ```swift
/// MockURLProtocol.stub("https://example.com/audio.mp3") { _ in
///     (.init(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("audio"))
/// }
/// ```
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    // MARK: - Handler registry

    // NSLock-protected mutable state — @unchecked Sendable because all accesses
    // go through `lock`. Swift 6 treats nonisolated static var as an error, so
    // we suppress the check here; the design guarantee is upheld by the lock.
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func stub(
        _ urlString: String,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock { handlers[urlString] = handler }
    }

    @discardableResult
    static func removeStub(_ urlString: String) -> Bool {
        lock.withLock { handlers.removeValue(forKey: urlString) != nil }
    }

    static func removeAllStubs() {
        lock.withLock { handlers.removeAll() }
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard let urlString = request.url?.absoluteString else { return false }
        return lock.withLock { handlers[urlString] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let urlString = request.url?.absoluteString,
              let handler = MockURLProtocol.lock.withLock({ MockURLProtocol.handlers[urlString] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - URLSessionDownloaderTests

final class URLSessionDownloaderTests: XCTestCase {

    private var tmpDir: URL!
    private var mockSession: URLSession!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLSessionDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
    }

    override func tearDownWithError() throws {
        MockURLProtocol.removeAllStubs()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeDownloader() -> URLSessionDownloader {
        URLSessionDownloader(mediaDir: tmpDir, session: mockSession)
    }

    private func makeEpisode(
        guid: String = "ep-001",
        mp3Url: String = "https://cdn.example.com/ep-001.mp3"
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: "test-show",
            title: "Test Episode",
            pubDate: "2024-01-01",
            mp3Url: mp3Url
        )
    }

    // MARK: - 1. Successful download

    func testSuccessfulDownload() async throws {
        let audioURL = "https://cdn.example.com/ep-001.mp3"
        let fakeAudio = Data("fake-mp3-content".utf8)

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (resp, fakeAudio)
        }

        let episode = makeEpisode(guid: "ep-001", mp3Url: audioURL)
        let downloader = makeDownloader()
        let localURL = try await downloader.download(episode)

        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path),
                      "Downloaded file must exist on disk")
        let writtenData = try Data(contentsOf: localURL)
        XCTAssertEqual(writtenData, fakeAudio,
                       "Written content must match served data")
    }

    // MARK: - 2. Content-Length exceeds maxMP3Bytes → permanent

    func testContentLengthExceedsCapThrowsPermanent() async throws {
        let audioURL = "https://cdn.example.com/toobig.mp3"
        let overLimit = URLSafety.maxMP3Bytes + 1

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "\(overLimit)"
                ]
            )!
            return (resp, Data())
        }

        let episode = makeEpisode(guid: "toobig", mp3Url: audioURL)
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for oversized content")
        } catch PipelineError.permanent(let msg) {
            XCTAssertTrue(msg.contains("Content-Length") || msg.contains("exceeds"),
                          "Error message should mention size cap: \(msg)")
        }
    }

    // MARK: - 3. HTTP 404 → permanent

    func testHTTP404MapsToPermanent() async throws {
        let audioURL = "https://cdn.example.com/notfound.mp3"

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let episode = makeEpisode(guid: "notfound", mp3Url: audioURL)
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for 404")
        } catch PipelineError.permanent(let msg) {
            XCTAssertTrue(msg.contains("404"), "Error message must mention HTTP 404: \(msg)")
        }
    }

    // MARK: - 4. HTTP 403 → permanent

    func testHTTP403MapsToPermanent() async throws {
        let audioURL = "https://cdn.example.com/forbidden.mp3"

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let episode = makeEpisode(guid: "forbidden", mp3Url: audioURL)
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for 403")
        } catch PipelineError.permanent(let msg) {
            XCTAssertTrue(msg.contains("403"), "Error message must mention HTTP 403: \(msg)")
        }
    }

    // MARK: - 5. HTTP 503 → transient

    func testHTTP503MapsToTransient() async throws {
        let audioURL = "https://cdn.example.com/unavailable.mp3"

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let episode = makeEpisode(guid: "unavailable", mp3Url: audioURL)
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for 503")
        } catch PipelineError.transient(let msg) {
            XCTAssertTrue(msg.contains("503"), "Error message must mention HTTP 503: \(msg)")
        }
    }

    // MARK: - 6. HTTP 429 → transient

    func testHTTP429MapsToTransient() async throws {
        let audioURL = "https://cdn.example.com/ratelimited.mp3"

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let episode = makeEpisode(guid: "ratelimited", mp3Url: audioURL)
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for 429")
        } catch PipelineError.transient(let msg) {
            XCTAssertTrue(msg.contains("429"), "Error message must mention HTTP 429: \(msg)")
        }
    }

    // MARK: - 7. URL safety check failure → permanent

    func testURLSafetyCheckBlocksPrivateHost() async throws {
        // 127.0.0.1 is a loopback address — safeURL should reject it.
        let episode = makeEpisode(guid: "ssrf", mp3Url: "http://127.0.0.1/evil.mp3")
        let downloader = makeDownloader()

        do {
            _ = try await downloader.download(episode)
            XCTFail("Should have thrown for private host URL")
        } catch PipelineError.permanent(let msg) {
            XCTAssertTrue(msg.contains("safety") || msg.contains("URL") || msg.contains("private"),
                          "Error message should mention URL safety: \(msg)")
        }
    }

    // MARK: - 8. YouTube URL → delegates to hook

    func testYouTubeURLDelegatesToHook() async throws {
        let episode = makeEpisode(
            guid: "yt-ep",
            mp3Url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )

        let hookExpectation = expectation(description: "YouTube hook called")
        let fakeResult = FileManager.default.temporaryDirectory.appendingPathComponent("yt.mp3")

        let downloader = URLSessionDownloader(
            mediaDir: tmpDir,
            session: mockSession,
            youtubeAudioHook: { _, _ in
                hookExpectation.fulfill()
                return fakeResult
            }
        )

        let result = try await downloader.download(episode)
        await fulfillment(of: [hookExpectation], timeout: 1)
        XCTAssertEqual(result, fakeResult)
    }

    // MARK: - Pure helper tests (no network)

    func testIsRetriableStatus() {
        XCTAssertTrue(URLSessionDownloader.isRetriableStatus(429))
        XCTAssertTrue(URLSessionDownloader.isRetriableStatus(500))
        XCTAssertTrue(URLSessionDownloader.isRetriableStatus(502))
        XCTAssertTrue(URLSessionDownloader.isRetriableStatus(503))
        XCTAssertTrue(URLSessionDownloader.isRetriableStatus(504))
        XCTAssertFalse(URLSessionDownloader.isRetriableStatus(404))
        XCTAssertFalse(URLSessionDownloader.isRetriableStatus(403))
        XCTAssertFalse(URLSessionDownloader.isRetriableStatus(200))
    }

    func testIsYouTubeURL() {
        XCTAssertTrue(URLSessionDownloader.isYouTubeURL(URL(string: "https://www.youtube.com/watch?v=abc")!))
        XCTAssertTrue(URLSessionDownloader.isYouTubeURL(URL(string: "https://youtube.com/watch?v=abc")!))
        XCTAssertTrue(URLSessionDownloader.isYouTubeURL(URL(string: "https://youtu.be/abc")!))
        XCTAssertFalse(URLSessionDownloader.isYouTubeURL(URL(string: "https://cdn.example.com/ep.mp3")!))
        XCTAssertFalse(URLSessionDownloader.isYouTubeURL(URL(string: "https://vimeo.com/123")!))
    }

    func testMakeSlugStripsSpecialChars() {
        let ep = Episode(
            guid: "GUID With Spaces & Symbols! 🎙️ 2024",
            showSlug: "show",
            title: "T",
            pubDate: "2024-01-01",
            mp3Url: "https://x.com/e.mp3"
        )
        let slug = URLSessionDownloader.makeSlug(ep)
        let forbidden = CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).inverted
        XCTAssertTrue(slug.unicodeScalars.allSatisfy { !forbidden.contains($0) })
        XCTAssertFalse(slug.isEmpty)
    }

    // MARK: - H5: buffered chunked write round-trips a multi-chunk payload

    /// A payload larger than the 64 KB write buffer must survive the chunked-write
    /// path byte-for-byte — proving the buffering (multiple flushes + the final
    /// partial flush) doesn't drop or reorder any bytes.
    func testMultiChunkDownloadRoundTripsExactly() async throws {
        let audioURL = "https://cdn.example.com/big.mp3"
        // 200 000 bytes ≈ 3 full 64 KB chunks + a partial → exercises every flush
        // branch. Non-repeating content so a truncation/duplication would show.
        let payload: Data = {
            var d = Data(capacity: 200_000)
            for i in 0..<200_000 { d.append(UInt8(i % 251)) }
            return d
        }()

        MockURLProtocol.stub(audioURL) { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"])!
            return (resp, payload)
        }

        let episode = makeEpisode(guid: "big", mp3Url: audioURL)
        let localURL = try await makeDownloader().download(episode)
        let written = try Data(contentsOf: localURL)
        XCTAssertEqual(written.count, payload.count, "byte count must match exactly")
        XCTAssertEqual(written, payload, "chunked write must be byte-for-byte identical")
    }

    // MARK: - M12: ENOSPC / out-of-space classification

    func testIsOutOfSpaceRecognisesCocoaError() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertTrue(URLSessionDownloader.isOutOfSpace(cocoa))
    }

    func testIsOutOfSpaceRecognisesPOSIXENOSPC() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertTrue(URLSessionDownloader.isOutOfSpace(posix))
    }

    func testIsOutOfSpaceRecognisesNestedUnderlyingENOSPC() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(URLSessionDownloader.isOutOfSpace(cocoa))
    }

    func testIsOutOfSpaceIgnoresUnrelatedError() {
        let other = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertFalse(URLSessionDownloader.isOutOfSpace(other))
    }

    func testClassifyWriteErrorMapsENOSPCToDiskFull() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        guard case .diskFull = URLSessionDownloader.classifyWriteError(posix) else {
            return XCTFail("ENOSPC write must classify as .diskFull")
        }
    }

    func testClassifyWriteErrorMapsOtherToTransient() {
        // A non-space write failure is transient (leave .part for resume).
        let other = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        guard case .transient = URLSessionDownloader.classifyWriteError(other) else {
            return XCTFail("a non-space write error must classify as .transient")
        }
    }

    func testClassifyErrorMapsENOSPCToDiskFull() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        guard case .diskFull = URLSessionDownloader.classifyError(cocoa) else {
            return XCTFail("an out-of-space error reaching classifyError must be .diskFull")
        }
    }
}
