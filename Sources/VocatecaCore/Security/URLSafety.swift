import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - URLSafetyError

/// Errors thrown by ``URLSafety/safeURL(_:allowPrivate:)``.
///
/// Mirrors the ``UnsafeURLError`` semantics from `core/security.py`.
public enum URLSafetyError: Error, Sendable {
    /// The URL string was empty or whitespace-only.
    case empty
    /// The URL's scheme is not `http` or `https`.
    case refusedScheme(String)
    /// The URL has no host component.
    case noHost
    /// The resolved host is a private/loopback/reserved address (SSRF guard).
    case privateHost(String)
}

// MARK: - URLSafety

/// URL safety helpers ported from ``core/security.py``.
///
/// ## Size caps (from Python constants)
/// - ``maxFeedBytes`` — 50 MB (`MAX_FEED_BYTES = 50 * 1024 * 1024`)
/// - ``maxMP3Bytes``  — 2 GB  (`MAX_MP3_BYTES = 2 * 1024 * 1024 * 1024`)
///
/// ## SSRF guard
/// ``safeURL(_:allowPrivate:)`` raises ``URLSafetyError`` unless the URL uses
/// `http` or `https`, has a non-empty host, and the host does not resolve to a
/// private/loopback/link-local/multicast/reserved/unspecified IP.
///
/// ``isPrivateHost(_:)`` mirrors `_is_private_ip` in `core/security.py`,
/// including the IPv4-mapped IPv6 (`::ffff:x.x.x.x`) and NAT64
/// (`64:ff9b::/96`, `64:ff9b:1::/48`) unwraps so that valid public hosts on
/// NAT64 networks are not incorrectly blocked.
public enum URLSafety {

    // MARK: - Size caps

    /// Maximum RSS/Atom feed size in bytes (50 MB).
    ///
    /// Mirrors `MAX_FEED_BYTES = 50 * 1024 * 1024` in `core/security.py`.
    public static let maxFeedBytes: Int = 50 * 1024 * 1024

    /// Maximum MP3/audio download size in bytes (2 GB).
    ///
    /// Mirrors `MAX_MP3_BYTES = 2 * 1024 * 1024 * 1024` in `core/security.py`.
    public static let maxMP3Bytes: Int = 2 * 1024 * 1024 * 1024

    // MARK: - safeURL

    /// Validate `url` and return it unchanged if safe to fetch, otherwise throw.
    ///
    /// Mirrors `safe_url(url, *, allow_private=False)` from `core/security.py`.
    ///
    /// - Parameters:
    ///   - url: The URL string to validate.
    ///   - allowPrivate: When `true`, private/loopback hosts are permitted
    ///     (developer debug use only — not used in production).
    /// - Returns: `url` unchanged.
    /// - Throws: ``URLSafetyError`` describing the specific violation.
    @discardableResult
    public static func safeURL(_ url: String, allowPrivate: Bool = false) throws -> String {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLSafetyError.empty
        }

        // Use URLComponents for reliable scheme + host extraction.
        // Falls back to URL for URLs that URLComponents chokes on.
        guard let components = URLComponents(string: url) else {
            throw URLSafetyError.noHost
        }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw URLSafetyError.refusedScheme(scheme.isEmpty ? (components.scheme ?? "") : scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw URLSafetyError.noHost
        }

        if !allowPrivate && isPrivateHost(host) {
            throw URLSafetyError.privateHost(host)
        }

        return url
    }

    // MARK: - isPrivateHost

    /// Return `true` if `host` resolves to a private, loopback, link-local,
    /// multicast, reserved, or unspecified IP address.
    ///
    /// Mirrors `_is_private_ip` from `core/security.py`:
    ///
    /// 1. If `host` is an IPv4 or IPv6 literal, classify it directly (no DNS).
    /// 2. Otherwise resolve via POSIX `getaddrinfo` and classify each result.
    /// 3. Resolution failure → `false` (downstream fetch fails cleanly — same
    ///    behaviour as Python's `socket.gaierror` handler).
    ///
    /// IPv6 unwraps applied before classification:
    /// - **IPv4-mapped** (`::ffff:x.x.x.x` per RFC 4291) — classify the
    ///   embedded IPv4.
    /// - **NAT64 well-known prefix** (`64:ff9b::/96` per RFC 6052) and
    ///   **local NAT64** (`64:ff9b:1::/48` per RFC 8215) — extract the
    ///   embedded IPv4 from the low 32 bits.
    public static func isPrivateHost(_ host: String) -> Bool {
        // Strip IPv6 bracket notation if present (e.g. "[::1]" → "::1")
        let bare = stripIPv6Brackets(host)

        // Fast path: if the host string is already an IP literal, classify directly.
        if let v4 = parseIPv4(bare) {
            return isPrivateIPv4(v4)
        }
        if let v6 = parseIPv6(bare) {
            return isPrivateIPv6Unwrapped(v6)
        }

        // Slow path: resolve hostname via getaddrinfo.
        return resolveAndClassify(hostname: bare)
    }

    // MARK: - boundedData

    /// Fetch `url` with a byte cap, aborting once accumulated bytes exceed `maxBytes`.
    ///
    /// Uses `URLSession.bytes(for:)` to stream the response incrementally, so a
    /// malicious or unexpectedly large resource cannot OOM the process.
    ///
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - maxBytes: Abort if more than this many bytes arrive.
    ///   - timeout: Request timeout in seconds (default 30).
    ///   - session: URLSession to use (injectable for tests; defaults to `.shared`).
    /// - Returns: The complete response body as `Data`.
    /// - Throws: ``URLSafetyError`` or any network/timeout error from URLSession.
    ///   When the cap is exceeded, throws `URLError(.dataLengthExceedsMaximum)`.
    public static func boundedData(
        from url: URL,
        maxBytes: Int,
        timeout: TimeInterval = 30,
        userAgent: String? = nil,
        session: URLSession = .shared
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Some hosts (e.g. Spotify's open.spotify.com) serve a stripped page
        // without Open Graph meta tags to the default CFNetwork/Darwin agent;
        // a browser User-Agent gets the full page. Opt-in per caller.
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        // Re-validate redirect targets so a public host can't 302-bounce us to a
        // private/loopback address (SSRF via redirect). Build a session from the
        // caller's configuration (preserving any test URLProtocol) plus a delegate
        // that runs `safeURL` on each redirect hop and blocks unsafe ones.
        let validating = URLSession(
            configuration: session.configuration,
            delegate: RedirectValidator(),
            delegateQueue: nil
        )
        defer { validating.finishTasksAndInvalidate() }

        let (asyncBytes, response) = try await validating.bytes(for: request)

        // Hint from Content-Length header so we can reject early.
        if let httpResponse = response as? HTTPURLResponse,
           let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(contentLength), length > maxBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        for try await byte in asyncBytes {
            data.append(byte)
            if data.count > maxBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return data
    }

    /// Fetch only the **head** of `url` — up to `maxBytes` — and return whatever
    /// was streamed, truncated rather than thrown when the full resource is
    /// larger than the cap.
    ///
    /// Unlike ``boundedData(from:maxBytes:timeout:userAgent:session:)``, this is
    /// for callers that only need a small leading slice of a resource that may
    /// legitimately be much larger overall (e.g. reading a podcast RSS feed's
    /// `<channel>` block, which precedes potentially megabytes of `<item>`s). A
    /// too-large resource is the *expected* case here, not an error to guard
    /// against, so it does not throw `dataLengthExceedsMaximum` and ignores the
    /// `Content-Length` early-reject that `boundedData` uses to bail before the
    /// caller-relevant head has even been read.
    ///
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - maxBytes: Stop reading — and return what's been read so far — once
    ///     this many bytes have arrived.
    ///   - timeout: Request timeout in seconds (default 30).
    ///   - session: URLSession to use (injectable for tests; defaults to `.shared`).
    /// - Returns: Up to `maxBytes` of the response body, however much arrived.
    /// - Throws: ``URLSafetyError`` or any network/timeout error from URLSession
    ///   (connection failures still throw — only the "resource bigger than cap"
    ///   case is downgraded to a truncated return).
    public static func boundedHeadData(
        from url: URL,
        maxBytes: Int,
        timeout: TimeInterval = 30,
        userAgent: String? = nil,
        session: URLSession = .shared
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let validating = URLSession(
            configuration: session.configuration,
            delegate: RedirectValidator(),
            delegateQueue: nil
        )
        defer { validating.finishTasksAndInvalidate() }

        let (asyncBytes, _) = try await validating.bytes(for: request)

        var data = Data()
        data.reserveCapacity(min(maxBytes, 1 << 20))
        for try await byte in asyncBytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return data
    }
}

// MARK: - Redirect SSRF guard

public extension URLSafety {
    /// A `URLSession` that re-validates every HTTP redirect target via `safeURL`
    /// (blocks 302-to-private-host SSRF). Use this for any fetch that follows
    /// redirects — including streaming downloads that can't use `boundedData`.
    /// Built from `configuration` so callers can preserve a test URLProtocol.
    static func redirectValidatingSession(
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        // Episode audio can be large / arrive on slow connections — apply a hard
        // resource (total wall-clock) cap so a stalled transfer eventually times out.
        // The existing per-request inactivity window catches true stalls earlier.
        // Tests pass a custom URLProtocol configuration; we honour it and only add
        // the resource cap they won't have set.
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: RedirectValidator(), delegateQueue: nil)
    }
}

/// URLSession delegate that re-validates every HTTP redirect target through
/// `URLSafety.safeURL`, blocking a redirect to a private/loopback host. Stateless
/// → safe to share across tasks.
private final class RedirectValidator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, (try? URLSafety.safeURL(url.absoluteString)) != nil {
            completionHandler(request)   // safe → follow
        } else {
            completionHandler(nil)       // unsafe → stop at current response
        }
    }
}

// MARK: - IPv4 parsing & classification

private extension URLSafety {

    /// Parse an IPv4 dotted-decimal string into four bytes. Returns `nil` for
    /// anything that is not a valid IPv4 literal.
    static func parseIPv4(_ s: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes = [UInt8]()
        for p in parts {
            guard let v = UInt16(p), v <= 255 else { return nil }
            bytes.append(UInt8(v))
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// Classify an IPv4 address (as four bytes) as private/loopback/etc.
    ///
    /// Ranges checked (matching Python's `ipaddress` `is_private` / `is_loopback`
    /// / `is_link_local` / `is_multicast` / `is_reserved` / `is_unspecified`):
    ///
    /// | Range             | Class                                 |
    /// |-------------------|---------------------------------------|
    /// | 0.0.0.0/8         | unspecified + reserved (0.x.x.x)     |
    /// | 10.0.0.0/8        | private (RFC 1918)                    |
    /// | 100.64.0.0/10     | private (CGNAT, RFC 6598)             |
    /// | 127.0.0.0/8       | loopback                              |
    /// | 169.254.0.0/16    | link-local                            |
    /// | 172.16.0.0/12     | private (RFC 1918)                    |
    /// | 192.0.0.0/24      | reserved (IETF Protocol Assignments)  |
    /// | 192.168.0.0/16    | private (RFC 1918)                    |
    /// | 198.18.0.0/15     | reserved (benchmarking)               |
    /// | 198.51.100.0/24   | reserved (TEST-NET-2)                 |
    /// | 203.0.113.0/24    | reserved (TEST-NET-3)                 |
    /// | 224.0.0.0/4       | multicast                             |
    /// | 240.0.0.0/4       | reserved                              |
    /// | 255.255.255.255   | limited broadcast                     |
    ///
    /// Python's `is_private` (3.11+) includes CGNAT (100.64/10); we match that.
    static func isPrivateIPv4(_ b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b2, b3, _) = b
        // 0.x.x.x — unspecified / reserved
        if a == 0 { return true }
        // 10.x.x.x — RFC 1918 private
        if a == 10 { return true }
        // 100.64.0.0/10 — CGNAT (RFC 6598); Python is_private includes this
        // Range: 100.64.0.0 – 100.127.255.255
        if a == 100 && (b2 & 0xC0) == 64 { return true }
        // 127.x.x.x — loopback
        if a == 127 { return true }
        // 169.254.x.x — link-local
        if a == 169 && b2 == 254 { return true }
        // 172.16.0.0/12 — RFC 1918 private (172.16.x.x – 172.31.x.x)
        if a == 172 && (b2 & 0xF0) == 16 { return true }
        // 192.0.0.0/24 — IETF Protocol Assignments (reserved)
        if a == 192 && b2 == 0 && b3 == 0 { return true }
        // 192.168.x.x — RFC 1918 private
        if a == 192 && b2 == 168 { return true }
        // 198.18.0.0/15 — benchmarking (reserved)
        if a == 198 && (b2 == 18 || b2 == 19) { return true }
        // 198.51.100.0/24 — TEST-NET-2 (reserved)
        if a == 198 && b2 == 51 && b3 == 100 { return true }
        // 203.0.113.0/24 — TEST-NET-3 (reserved)
        if a == 203 && b2 == 0 && b3 == 113 { return true }
        // 224.0.0.0/4 – 239.x.x.x — multicast
        if (a & 0xF0) == 224 { return true }
        // 240.0.0.0/4 – 255.x.x.x — reserved (incl. 255.255.255.255)
        if (a & 0xF0) == 240 { return true }
        return false
    }
}

// MARK: - IPv6 parsing & classification

private extension URLSafety {

    /// Parse an IPv6 address string into 16 bytes.
    /// Handles full form, compressed `::` notation, and IPv4-mapped suffixes.
    /// Returns `nil` for anything that is not a valid IPv6 literal.
    static func parseIPv6(_ s: String) -> [UInt8]? {
        // We delegate to getaddrinfo for parsing to handle all compressed forms.
        // This is a one-shot call on a literal so it is synchronous and cheap.
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_INET6
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(s, nil, &hints, &res) == 0, let info = res else {
            return nil
        }
        defer { freeaddrinfo(res) }
        guard info.pointee.ai_family == AF_INET6,
              let sa = info.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
            withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
        }
    }

    /// Classify an IPv6 address (16 bytes), unwrapping embedded IPv4 first.
    ///
    /// Unwraps applied (same as Python `_is_private_ip`):
    /// - **IPv4-mapped** `::ffff:x.x.x.x`: bytes 0-9 = 0x00, bytes 10-11 = 0xff.
    ///   Classify the low 4 bytes as IPv4.
    /// - **NAT64 WKP** `64:ff9b::/96` (RFC 6052): first 12 bytes match
    ///   `00 64 ff 9b 00 00 00 00 00 00 00 00`. Classify low 4 bytes as IPv4.
    /// - **Local NAT64** `64:ff9b:1::/48` (RFC 8215): first 6 bytes match
    ///   `00 64 ff 9b 00 01`. Classify low 4 bytes as IPv4.
    ///
    /// Ranges checked without unwrapping:
    /// - `::` (all zeros) — unspecified
    /// - `::1` — loopback
    /// - `fe80::/10` — link-local (bytes[0]=0xFE, bytes[1] & 0xC0 == 0x80)
    /// - `fc00::/7`  — ULA private (bytes[0] & 0xFE == 0xFC)
    /// - `ff00::/8`  — multicast (bytes[0] == 0xFF)
    static func isPrivateIPv6Unwrapped(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        // IPv4-mapped: ::ffff:x.x.x.x
        // Bytes 0-9 are 0x00, bytes 10-11 are 0xFF 0xFF
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
        }

        // NAT64 well-known prefix: 64:ff9b::/96
        // In network byte order: 00 64 ff 9b 00 00 00 00 00 00 00 00 | IPv4 (last 4)
        let nat64WKP: [UInt8] = [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        if Array(bytes[0...11]) == nat64WKP {
            return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
        }

        // Local NAT64 prefix: 64:ff9b:1::/48
        // In network byte order: 00 64 ff 9b 00 01 | …
        let nat64Local: [UInt8] = [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01]
        if Array(bytes[0...5]) == nat64Local {
            return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
        }

        // Unspecified: ::  (all zero)
        if bytes.allSatisfy({ $0 == 0 }) { return true }

        // Loopback: ::1
        if bytes[0...14].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }

        // Link-local: fe80::/10
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }

        // ULA private: fc00::/7  (covers fc00:: and fd00:: ranges)
        if (bytes[0] & 0xFE) == 0xFC { return true }

        // Multicast: ff00::/8
        if bytes[0] == 0xFF { return true }

        return false
    }
}

// MARK: - DNS resolution

private extension URLSafety {

    /// Resolve `hostname` via POSIX `getaddrinfo` and classify each result.
    ///
    /// - Returns `true` if **any** resolved address is private/loopback/etc.
    /// - Returns `false` on resolution failure (mirrors Python `socket.gaierror`
    ///   handler: "Unknown host — downstream fetch fails cleanly").
    static func resolveAndClassify(hostname: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let err = getaddrinfo(hostname, nil, &hints, &res)
        guard err == 0, let head = res else {
            // Resolution failure → allow (not blocked)
            return false
        }
        defer { freeaddrinfo(head) }

        var current: UnsafeMutablePointer<addrinfo>? = head
        while let info = current {
            defer { current = info.pointee.ai_next }
            guard let addr = info.pointee.ai_addr else { continue }

            switch Int32(info.pointee.ai_family) {
            case AF_INET:
                let isPrivate = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    let raw = p.pointee.sin_addr.s_addr.bigEndian
                    let b0 = UInt8((raw >> 24) & 0xFF)
                    let b1 = UInt8((raw >> 16) & 0xFF)
                    let b2 = UInt8((raw >> 8) & 0xFF)
                    let b3 = UInt8(raw & 0xFF)
                    return isPrivateIPv4((b0, b1, b2, b3))
                }
                if isPrivate { return true }

            case AF_INET6:
                let isPrivate = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin6_addr) { rawBytes in
                        isPrivateIPv6Unwrapped(Array(rawBytes))
                    }
                }
                if isPrivate { return true }

            default:
                continue
            }
        }
        return false
    }

    /// Remove surrounding brackets from an IPv6 literal, e.g. `[::1]` → `::1`.
    static func stripIPv6Brackets(_ s: String) -> String {
        guard s.hasPrefix("[") && s.hasSuffix("]") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
