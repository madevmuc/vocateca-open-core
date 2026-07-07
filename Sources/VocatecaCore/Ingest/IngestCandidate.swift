import Foundation

// MARK: - IngestCandidate

/// A file the user dropped / picked for local ingest, classified for the review
/// list: its media type (for the row icon) and whether the pipeline can transcribe
/// it. Pure value type — the staging UI holds an array of these before the user
/// confirms which ones to enqueue.
public struct IngestCandidate: Sendable, Equatable, Identifiable {

    public enum MediaType: String, Sendable, Equatable {
        case audio, video, unsupported
    }

    /// The source file URL.
    public let url: URL
    /// Classified media type (drives the row icon).
    public let mediaType: MediaType

    /// Stable identity for SwiftUI lists (the absolute path).
    public var id: String { url.path }
    /// The file's display name.
    public var name: String { url.lastPathComponent }
    /// Whether the pipeline can transcribe this file. `false` for `.unsupported`.
    public var isIngestable: Bool { mediaType != .unsupported }

    public init(url: URL, mediaType: MediaType) {
        self.url       = url
        self.mediaType = mediaType
    }
}

// MARK: - IngestCandidateClassifier

/// Classifies a file URL into an ``IngestCandidate`` by extension.
///
/// The audio/video split mirrors ``FolderScan/mediaExtensions`` (the pipeline's
/// single source of truth for ingestable media); anything outside both sets is
/// `.unsupported` and gets pre-deselected in the review list.
public enum IngestCandidateClassifier {

    /// Audio extensions (subset of `FolderScan.mediaExtensions`).
    public static let audioExtensions: Set<String> =
        [".mp3", ".m4a", ".m4b", ".wav", ".aiff", ".aif", ".flac", ".ogg", ".oga", ".opus"]

    /// Video extensions (subset of `FolderScan.mediaExtensions`).
    public static let videoExtensions: Set<String> =
        [".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv"]

    public static func classify(_ url: URL) -> IngestCandidate {
        let ext = "." + url.pathExtension.lowercased()
        let type: IngestCandidate.MediaType
        if audioExtensions.contains(ext)      { type = .audio }
        else if videoExtensions.contains(ext) { type = .video }
        else                                  { type = .unsupported }
        return IngestCandidate(url: url, mediaType: type)
    }

    /// Classifies a batch, preserving order and de-duplicating by path (so
    /// re-dropping a file already staged does not add a duplicate row).
    public static func classify(urls: [URL], excludingPaths existing: Set<String> = []) -> [IngestCandidate] {
        var seen = existing
        var out: [IngestCandidate] = []
        for url in urls {
            let path = url.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(classify(url))
        }
        return out
    }
}
