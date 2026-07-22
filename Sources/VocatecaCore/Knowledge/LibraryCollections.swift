import Foundation

// MARK: - Library collections ("folders")

/// A user-created Library folder is a pure ORGANISATIONAL OVERLAY: it holds
/// *links* to shows and/or episodes, never the underlying content. Removing a
/// link (or deleting a whole collection) only drops the membership — the show,
/// its episodes, and their transcripts are untouched.

/// One membership link inside a collection: either a whole show (all its
/// episodes) or a single episode.
public struct LibraryCollectionItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case show, episode }

    /// `.show` → `ref` is the show slug; `.episode` → `ref` is the episode guid.
    public var kind: Kind
    public var ref: String
    /// ISO-8601 timestamp of when the link was added (newest-first ordering).
    public var addedAt: String

    /// Stable identity for dedupe + SwiftUI: a link is unique by (kind, ref).
    public var id: String { "\(kind.rawValue):\(ref)" }

    public init(kind: Kind, ref: String, addedAt: String) {
        self.kind = kind
        self.ref = ref
        self.addedAt = addedAt
    }
}

/// A named folder of membership links.
public struct LibraryCollection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: String
    public var items: [LibraryCollectionItem]

    public init(id: String, name: String, createdAt: String, items: [LibraryCollectionItem] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.items = items
    }
}

private struct LibraryCollectionsFile: Codable {
    var collections: [LibraryCollection]
}

/// Pure JSON persistence for Library collections. UI-only overlay — no DB, no
/// migration, never touches shows/episodes/transcripts.
public enum LibraryCollectionsStore {

    /// Loads all collections. Returns `[]` when the file is missing or unreadable
    /// (a fresh install, or a corrupt/edited file) — never throws on read so the
    /// Library still opens.
    public static func load(from url: URL = Paths.libraryCollectionsURL) -> [LibraryCollection] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return ((try? JSONDecoder().decode(LibraryCollectionsFile.self, from: data))?.collections) ?? []
    }

    /// Atomically writes all collections (pretty-printed, stable key order).
    public static func save(_ collections: [LibraryCollection],
                            to url: URL = Paths.libraryCollectionsURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LibraryCollectionsFile(collections: collections))
        try data.write(to: url, options: .atomic)
    }
}
