import XCTest
import Foundation
@testable import VocatecaCore

/// Lock-protected mutable box for capturing values from inside a `@Sendable`
/// `MockURLProtocol` handler closure (Swift 6 forbids mutating a plain
/// captured `var` from concurrently-executing code).
final class CapturedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ initial: Value) { _value = initial }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Integrations — Task 4: `NotionClient` HTTP behaviour.
///
/// Reuses the `MockURLProtocol` defined in
/// `Pipeline/Engines/URLSessionDownloaderTests.swift` (same test target,
/// `internal` visibility) — no live network is ever hit here.
final class NotionClientTests: XCTestCase {

    // MARK: - Helpers

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.removeAllStubs()
        super.tearDown()
    }

    // MARK: - 1. POSTs to the pages endpoint with a Bearer token

    func testCreatePagePostsToPagesEndpointWithBearer() async throws {
        let url = "https://api.notion.com/v1/pages"
        let capturedRequest = CapturedBox<URLRequest?>(nil)
        MockURLProtocol.stub(url) { req in
            capturedRequest.value = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"id":"page_1"}"#.utf8))
        }

        let client = NotionClient(token: "tok", session: makeMockSession())
        let id = try await client.createPage(databaseId: "db1", title: "Ep 1",
                                              properties: [:], blocks: ["hello"])

        XCTAssertEqual(id, "page_1")
        XCTAssertEqual(capturedRequest.value?.url?.absoluteString, url)
        XCTAssertEqual(capturedRequest.value?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(capturedRequest.value?.value(forHTTPHeaderField: "Notion-Version")?.isEmpty, false)
    }

    // MARK: - 2. Long transcript is chunked into many child blocks

    func testLongTranscriptIsChunkedIntoManyBlocks() async throws {
        let url = "https://api.notion.com/v1/pages"
        let captured = CapturedBox<Data>(Data())
        MockURLProtocol.stub(url) { req in
            captured.value = req.bodyData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"id":"p"}"#.utf8))
        }

        let big = String(repeating: "x", count: 5000)
        _ = try await NotionClient(token: "t", session: makeMockSession())
            .createPage(databaseId: "d", title: "t", properties: [:], blocks: [big])

        let obj = try JSONSerialization.jsonObject(with: captured.value) as? [String: Any]
        let children = (obj?["children"] as? [[String: Any]]) ?? []
        XCTAssertGreaterThan(children.count, 1)
    }

    // MARK: - 3. Only the "Name" title property is set

    func testOnlyNameTitlePropertyIsSet() async throws {
        let url = "https://api.notion.com/v1/pages"
        let captured = CapturedBox<Data>(Data())
        MockURLProtocol.stub(url) { req in
            captured.value = req.bodyData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"id":"p"}"#.utf8))
        }

        _ = try await NotionClient(token: "t", session: makeMockSession())
            .createPage(databaseId: "d", title: "My Title", properties: [:], blocks: [])

        let obj = try JSONSerialization.jsonObject(with: captured.value) as? [String: Any]
        let properties = (obj?["properties"] as? [String: Any]) ?? [:]
        XCTAssertEqual(properties.count, 1)
        XCTAssertNotNil(properties["Name"])
        let nameProp = properties["Name"] as? [String: Any]
        let titleArr = nameProp?["title"] as? [[String: Any]]
        let textObj = titleArr?.first?["text"] as? [String: Any]
        XCTAssertEqual(textObj?["content"] as? String, "My Title")
    }

    // MARK: - 4. Non-2xx maps to a thrown error

    func testHTTPErrorMapsToThrow() async throws {
        let url = "https://api.notion.com/v1/pages"
        MockURLProtocol.stub(url) { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"unauthorized"}"#.utf8))
        }

        do {
            _ = try await NotionClient(token: "bad", session: makeMockSession())
                .createPage(databaseId: "d", title: "t", properties: [:], blocks: [])
            XCTFail("Expected NotionClient.createPage to throw on HTTP 401")
        } catch {
            // expected
        }
    }

    // MARK: - 5. More than 100 blocks are truncated to the first 100

    func testMoreThan100BlocksAreTruncated() async throws {
        let url = "https://api.notion.com/v1/pages"
        let captured = CapturedBox<Data>(Data())
        MockURLProtocol.stub(url) { req in
            captured.value = req.bodyData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"id":"p"}"#.utf8))
        }

        let blocks = (0..<150).map { "line \($0)" }
        _ = try await NotionClient(token: "t", session: makeMockSession())
            .createPage(databaseId: "d", title: "t", properties: [:], blocks: blocks)

        let obj = try JSONSerialization.jsonObject(with: captured.value) as? [String: Any]
        let children = (obj?["children"] as? [[String: Any]]) ?? []
        XCTAssertLessThanOrEqual(children.count, 100)
    }
}

// MARK: - URLRequest body helper

extension URLRequest {
    /// Reads the full request body. `URLSession` moves `httpBody` into
    /// `httpBodyStream` once a request is dispatched through a custom
    /// `URLProtocol`, so `httpBody` alone is unreliable for inspection in
    /// tests — read the stream instead.
    func bodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
