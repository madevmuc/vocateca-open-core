import Foundation

// MARK: - NotionValue

/// A minimal JSON-value wrapper for Notion database property values.
///
/// v1 intentionally does not set arbitrary database properties (see
/// `NotionPageCreating.createPage` doc comment) — this type exists only to
/// keep the `properties:` parameter shape stable for future extension.
public enum NotionValue: Sendable, Equatable {
    case string(String)
}

// MARK: - NotionPageCreating

/// Abstraction over "create a page in a Notion database" so
/// `IntegrationSender` can be tested with a fake, no live network involved.
public protocol NotionPageCreating: Sendable {
    /// Creates a page in the given Notion database.
    ///
    /// - Parameters:
    ///   - databaseId: The target Notion database id.
    ///   - title: The page title. This is the ONLY database property v1 sets
    ///     (see the doc comment on `NotionClient.createPage`).
    ///   - properties: Reserved for future per-database property mapping.
    ///     v1 ignores this — the target database's schema is unknown, so
    ///     setting arbitrary Select/Date/Multi-select properties would make
    ///     Notion reject the request ("property does not exist").
    ///   - blocks: Plain-text paragraph blocks appended to the page body
    ///     (metadata + transcript). Each string is chunked to Notion's
    ///     `rich_text` character limit; at most 100 children are sent per
    ///     create request (Notion's per-request block limit).
    /// - Returns: The created page id.
    func createPage(databaseId: String, title: String, properties: [String: NotionValue], blocks: [String]) async throws -> String
}

// MARK: - NotionError

public enum NotionError: Error, Sendable, Equatable {
    /// Non-2xx HTTP response. `status` is the HTTP status code; `body` is the
    /// raw response body (if any) for diagnostics.
    case httpError(status: Int, body: String)
    /// The response body could not be decoded as JSON with an `id` field.
    case invalidResponse
}

// MARK: - NotionClient

/// HTTP client for the Notion "create a page" API
/// (`POST https://api.notion.com/v1/pages`).
///
/// ## Title-property assumption ("Name")
/// The user's target database schema is unknown at push time, so this client
/// sets **only** the title property, keyed as `"Name"` — Notion's default
/// name for a database's title property. All other metadata (source URL,
/// show, pub date, engine/model, language) and the transcript itself are
/// written into the page **body** as paragraph blocks, never as database
/// properties, so a push can never fail with "property does not exist" for
/// properties we don't control.
///
/// If the user renamed their database's title property away from `"Name"`,
/// `createPage` throws `NotionError.httpError` (Notion rejects the unknown
/// property) — the caller (`IntegrationSender`) surfaces this via the
/// delivery marker's `errorText` and a `Log.error` call. Full per-database
/// property mapping is out of scope for v1.
public struct NotionClient: NotionPageCreating {

    /// Notion's per-`rich_text`-element character limit.
    static let maxRichTextChars = 1900
    /// Notion's per-request `children` block-count limit.
    static let maxChildrenPerRequest = 100

    private static let apiVersion = "2022-06-28"
    private static let pagesURL = URL(string: "https://api.notion.com/v1/pages")!

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func createPage(databaseId: String, title: String, properties: [String: NotionValue], blocks: [String]) async throws -> String {
        let children = Self.makeChildren(from: blocks)

        let body: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": [
                "Name": [
                    "title": [
                        ["text": ["content": title]]
                    ]
                ]
            ],
            "children": children
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.pagesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(decoding: data, as: UTF8.self)
            throw NotionError.httpError(status: http.statusCode, body: bodyString)
        }

        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["id"] as? String
        else {
            throw NotionError.invalidResponse
        }
        return id
    }

    // MARK: - Chunking

    /// Splits `blocks` into Notion paragraph `children`, respecting both the
    /// per-`rich_text`-element character limit and the per-request children
    /// count limit. If the input would produce more than
    /// `maxChildrenPerRequest` children, only the first `maxChildrenPerRequest`
    /// are included and the truncation is logged by the caller
    /// (`IntegrationSender`) — full-fidelity multi-request append is out of
    /// scope for v1.
    static func makeChildren(from blocks: [String]) -> [[String: Any]] {
        var children: [[String: Any]] = []
        for block in blocks {
            for chunk in chunk(block, maxLength: maxRichTextChars) {
                children.append([
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": [
                        "rich_text": [
                            ["type": "text", "text": ["content": chunk]]
                        ]
                    ]
                ])
                if children.count >= maxChildrenPerRequest { break }
            }
            if children.count >= maxChildrenPerRequest { break }
        }
        if children.count > maxChildrenPerRequest {
            children = Array(children.prefix(maxChildrenPerRequest))
        }
        return children
    }

    /// Splits `text` into chunks of at most `maxLength` characters. Empty
    /// strings produce zero chunks (no empty paragraph blocks).
    static func chunk(_ text: String, maxLength: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(current, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[current..<next]))
            current = next
        }
        return result
    }
}
