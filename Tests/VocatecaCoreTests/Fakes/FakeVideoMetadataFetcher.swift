import Foundation
@testable import VocatecaCore

// MARK: - FakeVideoMetadataFetcher

/// A scriptable `YouTubeVideoMetadataFetching` test double.
///
/// Results are keyed by the exact `videoURL` string passed in. Any URL not
/// present in `script` returns `nil` — the same "could not determine
/// metadata" outcome `YtDlpVideoMetadataFetcher` produces on failure.
///
/// Records every call (`videoURL`) for assertion, and is safe to call from
/// concurrent tasks via an internal lock.
final class FakeVideoMetadataFetcher: YouTubeVideoMetadataFetching, @unchecked Sendable {

    private let lock = NSLock()
    private var script: [String: YouTubeVideoMeta]
    private var _calls: [String] = []

    /// All `videoURL`s passed to `fetchMeta`, in order.
    var calls: [String] { lock.withLock { _calls } }
    /// Total number of times `fetchMeta(videoURL:)` was called.
    var callCount: Int { lock.withLock { _calls.count } }

    /// - Parameter script: maps `videoURL` to the metadata to return. A URL
    ///   absent from `script` returns `nil`.
    init(script: [String: YouTubeVideoMeta] = [:]) {
        self.script = script
    }

    func fetchMeta(videoURL: String) async -> YouTubeVideoMeta? {
        lock.withLock {
            _calls.append(videoURL)
        }
        return script[videoURL]
    }
}
