import XCTest
@testable import VocatecaCore

// MARK: - URLSafetyTests

/// Tests for ``URLSafety``.
///
/// ## Structure
///
/// - **Pure unit tests** (no DNS, no network): IP-literal classification and
///   scheme/host validation against explicit IP literals.  These are deterministic
///   and must always pass.
///
/// - **DNS-dependent tests**: `localhost` and public hostname checks that require
///   DNS resolution.  Wrapped in `XCTSkip` where offline behaviour is acceptable.
///
/// - **`boundedData` tests**: cap enforcement.  The byte-cap test uses an in-
///   process HTTP server stub so it runs without external network.
final class URLSafetyTests: XCTestCase {

    // MARK: - Size constants

    func testMaxFeedBytes() {
        XCTAssertEqual(URLSafety.maxFeedBytes, 50 * 1024 * 1024,
                       "maxFeedBytes must equal Python's MAX_FEED_BYTES = 50 * 1024 * 1024")
    }

    func testMaxMP3Bytes() {
        XCTAssertEqual(URLSafety.maxMP3Bytes, 2 * 1024 * 1024 * 1024,
                       "maxMP3Bytes must equal Python's MAX_MP3_BYTES = 2 * 1024 * 1024 * 1024")
    }

    // MARK: - safeURL: accepted URLs

    func testSafeURL_httpsExampleCom() throws {
        let result = try URLSafety.safeURL("https://example.com/feed")
        XCTAssertEqual(result, "https://example.com/feed")
    }

    func testSafeURL_httpPodigee() throws {
        let result = try URLSafety.safeURL("http://podigee.io/x")
        XCTAssertEqual(result, "http://podigee.io/x")
    }

    // MARK: - safeURL: refused schemes

    func testSafeURL_fileScheme() {
        XCTAssertThrowsError(try URLSafety.safeURL("file:///etc/passwd")) { err in
            guard case URLSafetyError.refusedScheme(let s) = err else {
                return XCTFail("expected refusedScheme, got \(err)")
            }
            XCTAssertEqual(s, "file")
        }
    }

    func testSafeURL_dataScheme() {
        XCTAssertThrowsError(try URLSafety.safeURL("data:text/plain,hello")) { err in
            guard case URLSafetyError.refusedScheme = err else {
                return XCTFail("expected refusedScheme, got \(err)")
            }
        }
    }

    func testSafeURL_javascriptScheme() {
        XCTAssertThrowsError(try URLSafety.safeURL("javascript:alert(1)")) { err in
            guard case URLSafetyError.refusedScheme = err else {
                return XCTFail("expected refusedScheme, got \(err)")
            }
        }
    }

    // MARK: - safeURL: empty / no host

    func testSafeURL_emptyString() {
        XCTAssertThrowsError(try URLSafety.safeURL("")) { err in
            guard case URLSafetyError.empty = err else {
                return XCTFail("expected empty, got \(err)")
            }
        }
    }

    func testSafeURL_whitespaceOnly() {
        XCTAssertThrowsError(try URLSafety.safeURL("   ")) { err in
            guard case URLSafetyError.empty = err else {
                return XCTFail("expected empty, got \(err)")
            }
        }
    }

    func testSafeURL_noHost() {
        // "http://" with no host
        XCTAssertThrowsError(try URLSafety.safeURL("http:///path")) { err in
            // Either noHost or refusedScheme depending on URLComponents behaviour;
            // the important thing is it throws.
            XCTAssertTrue(
                {
                    if case URLSafetyError.noHost = err { return true }
                    if case URLSafetyError.refusedScheme = err { return true }
                    return false
                }(),
                "expected noHost or refusedScheme, got \(err)"
            )
        }
    }

    // MARK: - safeURL: private / loopback hosts (IP literals — deterministic)

    func testSafeURL_loopback_127_0_0_1() {
        XCTAssertThrowsError(try URLSafety.safeURL("http://127.0.0.1/")) { err in
            guard case URLSafetyError.privateHost = err else {
                return XCTFail("expected privateHost, got \(err)")
            }
        }
    }

    func testSafeURL_linkLocal_169_254() {
        XCTAssertThrowsError(try URLSafety.safeURL("http://169.254.1.1/")) { err in
            guard case URLSafetyError.privateHost = err else {
                return XCTFail("expected privateHost, got \(err)")
            }
        }
    }

    func testSafeURL_rfc1918_10_0_0_1() {
        XCTAssertThrowsError(try URLSafety.safeURL("http://10.0.0.1/")) { err in
            guard case URLSafetyError.privateHost = err else {
                return XCTFail("expected privateHost, got \(err)")
            }
        }
    }

    func testSafeURL_rfc1918_192_168() {
        XCTAssertThrowsError(try URLSafety.safeURL("http://192.168.1.1/")) { err in
            guard case URLSafetyError.privateHost = err else {
                return XCTFail("expected privateHost, got \(err)")
            }
        }
    }

    func testSafeURL_ipv6Loopback() {
        XCTAssertThrowsError(try URLSafety.safeURL("http://[::1]/")) { err in
            guard case URLSafetyError.privateHost = err else {
                return XCTFail("expected privateHost, got \(err)")
            }
        }
    }

    // MARK: - safeURL: localhost (DNS-dependent)

    func testSafeURL_localhost() {
        // localhost resolves to 127.0.0.1 / ::1 on most machines.
        // If DNS is broken in a bizarre way, we skip.
        do {
            try URLSafety.safeURL("http://localhost/")
            XCTFail("expected privateHost for localhost")
        } catch URLSafetyError.privateHost {
            // Expected
        } catch {
            // Unexpected error type — still fail
            XCTFail("unexpected error for localhost: \(error)")
        }
    }

    // MARK: - safeURL: public host (DNS-dependent)

    func testSafeURL_publicHost_exampleCom() throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network tests")
        }
        // example.com → public IPs. If offline / DNS fails, the guard returns
        // false (same as Python) and the URL is accepted — XCTSkip is fine.
        do {
            let result = try URLSafety.safeURL("https://example.com")
            XCTAssertEqual(result, "https://example.com")
        } catch URLSafetyError.privateHost {
            // example.com should never be private; if this fires, something is wrong.
            XCTFail("example.com was classified as private — check IP classification")
        } catch {
            // Other errors (e.g. truly offline DNS failure reaching a private guard)
            // are acceptable in network-restricted test environments.
            throw XCTSkip("DNS unavailable: \(error)")
        }
    }

    // MARK: - IP-literal classification (no DNS — fully deterministic)

    func testIsPrivateHost_loopback127() {
        XCTAssertTrue(URLSafety.isPrivateHost("127.0.0.1"))
    }

    func testIsPrivateHost_rfc1918_10() {
        XCTAssertTrue(URLSafety.isPrivateHost("10.1.2.3"))
    }

    func testIsPrivateHost_rfc1918_172_16() {
        XCTAssertTrue(URLSafety.isPrivateHost("172.16.0.1"))
    }

    func testIsPrivateHost_rfc1918_172_32_isPublic() {
        // 172.32.x.x is OUTSIDE the 172.16.0.0/12 range (which ends at 172.31.255.255)
        XCTAssertFalse(URLSafety.isPrivateHost("172.32.0.1"))
    }

    func testIsPrivateHost_rfc1918_192_168() {
        XCTAssertTrue(URLSafety.isPrivateHost("192.168.0.1"))
    }

    func testIsPrivateHost_linkLocal_169_254() {
        XCTAssertTrue(URLSafety.isPrivateHost("169.254.0.1"))
    }

    func testIsPrivateHost_publicDNS_8_8_8_8() {
        XCTAssertFalse(URLSafety.isPrivateHost("8.8.8.8"))
    }

    func testIsPrivateHost_ipv6Loopback() {
        XCTAssertTrue(URLSafety.isPrivateHost("::1"))
    }

    func testIsPrivateHost_ipv6LinkLocal() {
        XCTAssertTrue(URLSafety.isPrivateHost("fe80::1"))
    }

    func testIsPrivateHost_ipv6Public_cloudflare() {
        XCTAssertFalse(URLSafety.isPrivateHost("2606:4700:4700::1111"))
    }

    func testIsPrivateHost_ipv4MappedLoopback() {
        // ::ffff:127.0.0.1 — IPv4-mapped loopback should be detected as private
        XCTAssertTrue(URLSafety.isPrivateHost("::ffff:127.0.0.1"))
    }

    // MARK: - allowPrivate bypass

    func testSafeURL_allowPrivate_loopback() throws {
        // With allowPrivate=true, private IP literals should be accepted.
        let result = try URLSafety.safeURL("http://127.0.0.1/debug", allowPrivate: true)
        XCTAssertEqual(result, "http://127.0.0.1/debug")
    }

    // MARK: - boundedData: cap enforcement

    /// Test that ``URLSafety/boundedData(from:maxBytes:timeout:session:)`` aborts
    /// when the response exceeds `maxBytes`.
    ///
    /// Uses a real but tiny HTTP resource (example.com) guarded by `XCTSkip` when
    /// offline.  The first assertion checks that a generous cap returns data; the
    /// second checks that a 1-byte cap throws ``URLError/dataLengthExceedsMaximum``.
    func testBoundedData_capEnforced() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_NETWORK_TESTS=1 to run live-network tests")
        }
        guard let url = URL(string: "https://example.com") else {
            throw XCTSkip("cannot construct URL")
        }

        // Attempt with generous cap (should succeed if we have network)
        do {
            let data = try await URLSafety.boundedData(from: url, maxBytes: 1_000_000, timeout: 10)
            XCTAssertFalse(data.isEmpty, "expected non-empty response from example.com")
        } catch let urlError as URLError {
            throw XCTSkip("network unavailable: \(urlError.localizedDescription)")
        } catch {
            throw XCTSkip("network error: \(error)")
        }

        // Attempt with tiny cap — must throw
        do {
            _ = try await URLSafety.boundedData(from: url, maxBytes: 1, timeout: 10)
            XCTFail("expected dataLengthExceedsMaximum error for 1-byte cap")
        } catch let urlError as URLError where urlError.code == .dataLengthExceedsMaximum {
            // Correct — cap triggered
        } catch let urlError as URLError {
            throw XCTSkip("network unavailable: \(urlError.localizedDescription)")
        } catch {
            XCTFail("unexpected error type for cap test: \(error)")
        }
    }

    // MARK: - boundedHeadData: truncates instead of throwing (fixture, no network)

    /// Regression fixture for the podcast-search "description always empty"
    /// bug: a feed whose total size is far past the head cap (like real feeds —
    /// "#Gamechanger mit Toygar Cinar" is ~490 KB, "The Diary Of A CEO" is
    /// ~5.8 MB total) must still yield its truncated *head*, not an error,
    /// because the channel `<description>` sits well before the cap.
    ///
    /// Uses `MockURLProtocol` (see `URLSessionDownloaderTests.swift`) so this
    /// runs fully offline — no `VOCATECA_RUN_NETWORK_TESTS` gate needed.
    func testBoundedHeadData_largerThanCap_returnsTruncatedHeadNotThrow() async throws {
        let urlString = "https://example.com/feed-larger-than-cap.xml"
        let url = URL(string: urlString)!

        // Channel-level description + language sit in the first ~200 bytes;
        // the feed is then padded with a giant run of `<item>` filler so the
        // *total* response is well past the byte cap — mirroring a real feed
        // where the channel head is small but the whole document is megabytes.
        let head = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>#Gamechanger mit Toygar Cinar</title>
            <language>de-DE</language>
            <description>Der Podcast über Unternehmertum, Vertrieb und Erfolg.</description>
        """
        let itemFiller = String(repeating: "<item><title>Episode filler content padding out the feed well past the head cap so the response as a whole exceeds it.</title></item>\n", count: 4000)
        let tail = "\n  </channel>\n</rss>"
        let fullXML = head + "\n" + itemFiller + tail
        let fullData = fullXML.data(using: .utf8)!
        XCTAssertGreaterThan(fullData.count, 128 * 1024,
                              "fixture must exceed the 128 KB head cap to reproduce the bug")

        MockURLProtocol.stub(urlString) { req in
            let response = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/xml"])!
            return (response, fullData)
        }
        defer { MockURLProtocol.removeStub(urlString) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        // `boundedData` — the pre-fix API — must still throw for an
        // over-cap resource; this guards the original safety semantics.
        do {
            _ = try await URLSafety.boundedData(from: url, maxBytes: 128 * 1024, session: mockSession)
            XCTFail("expected boundedData to throw dataLengthExceedsMaximum for an over-cap resource")
        } catch let urlError as URLError where urlError.code == .dataLengthExceedsMaximum {
            // Expected — unchanged behaviour for the hard-cap API.
        }

        // `boundedHeadData` — the fix — must truncate instead of throwing, and
        // the truncated head must still contain the channel description text
        // (proving the parser gets a chance to run at all).
        let truncated = try await URLSafety.boundedHeadData(from: url, maxBytes: 128 * 1024, session: mockSession)
        XCTAssertFalse(truncated.isEmpty)
        XCTAssertLessThanOrEqual(truncated.count, 128 * 1024)
        XCTAssertLessThan(truncated.count, fullData.count,
                           "head must actually be truncated relative to the full resource")

        let parsed = RSSManifest.parseFeedChannelMeta(fromXML: truncated)
        XCTAssertTrue(parsed.description.contains("Unternehmertum"),
                      "truncated head must still carry the channel description")
        XCTAssertEqual(parsed.language, "de-DE")
    }
}
