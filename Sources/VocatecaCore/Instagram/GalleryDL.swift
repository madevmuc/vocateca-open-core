import Foundation

// MARK: - Data model

/// A single item downloaded by gallery-dl from an Instagram profile.
///
/// Field mapping from gallery-dl's Instagram extractor JSON:
/// - `url`       → direct media URL (string)
/// - `filename`  → local filename gallery-dl would write
/// - `shortcode` → Instagram post shortcode (e.g. "CxYz…")
/// - `caption`   → post caption text (may contain @mentions and URLs)
/// - `timestamp` → post date, encoded as ISO-8601 in our fixture JSON
/// - `mediaType` → `"image"` or `"video"`
public struct GalleryDLItem: Codable, Sendable, Equatable {
    public let url: String
    public let filename: String
    public let shortcode: String?
    public let caption: String?
    public let timestamp: Date?
    public let mediaType: String?

    public init(
        url: String,
        filename: String,
        shortcode: String? = nil,
        caption: String? = nil,
        timestamp: Date? = nil,
        mediaType: String? = nil
    ) {
        self.url = url
        self.filename = filename
        self.shortcode = shortcode
        self.caption = caption
        self.timestamp = timestamp
        self.mediaType = mediaType
    }

    // MARK: Coding keys

    enum CodingKeys: String, CodingKey {
        case url
        case filename
        case shortcode
        case caption
        case timestamp
        case mediaType = "media_type"
    }
}

// MARK: - Client protocol

/// Represents a source that enumerates downloaded items for an Instagram profile.
///
/// The protocol exists so Phase 2/3 can inject a real subprocess-backed
/// implementation without changing any caller — only the concrete type differs.
public protocol GalleryDLClient: Sendable {
    /// Returns all items available for `profile` (Instagram username).
    func enumerate(profile: String) async throws -> [GalleryDLItem]
}

// MARK: - Mock client

/// An in-process `GalleryDLClient` backed by canned JSON data.
///
/// - Date format in the JSON fixture: ISO 8601 with fractional seconds,
///   e.g. `"2024-03-15T10:30:00.000Z"`. The decoder uses `.iso8601` strategy
///   which handles the `Z`-suffix form. For the fixture we omit fractional
///   seconds; `.iso8601` handles plain `"2024-03-15T10:30:00Z"` as well.
///
/// This type never spawns a process or opens a network connection.
public struct MockGalleryDLClient: GalleryDLClient {
    private let items: [GalleryDLItem]

    // MARK: - Initialisation

    /// Initialises the client by decoding `jsonData`.
    ///
    /// - Parameter jsonData: A JSON array of objects whose fields match
    ///   `GalleryDLItem`'s `CodingKeys` (see type documentation for date format).
    /// - Throws: `DecodingError` if the JSON is malformed or fields are missing.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = try decoder.decode([GalleryDLItem].self, from: jsonData)
    }

    /// Initialises the client from a JSON file on disk.
    ///
    /// - Throws: Any error from reading the file or decoding its contents.
    public init(fixtureURL: URL) throws {
        let data = try Data(contentsOf: fixtureURL)
        try self.init(jsonData: data)
    }

    // MARK: - GalleryDLClient

    /// Returns the canned items regardless of `profile`.
    ///
    /// The `profile` parameter is accepted to satisfy the protocol but is
    /// intentionally ignored by this mock — the fixture represents a pre-fetched
    /// set of items for a single profile.
    public func enumerate(profile: String) async throws -> [GalleryDLItem] {
        items
    }
}
