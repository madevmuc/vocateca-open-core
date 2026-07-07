import Foundation

// MARK: - ForceTranscribeStore

/// A one-shot per-episode "force transcription" flag, used to OVERRIDE the
/// no-speech / music skip ("Transcribe anyway"). The UI sets the flag when the
/// user overrides a skipped episode; the `Pipeline` reads it before applying the
/// `NoSpeechDetector` and clears it after consuming it (so it only forces one run).
///
/// UserDefaults-backed so the UI (setter) and the Pipeline (reader/clearer) share
/// state across the in-process layers — mirrors `AutoDownloadStore`.
public struct ForceTranscribeStore: @unchecked Sendable {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ guid: String) -> String { "forceTranscribe-\(guid)" }

    /// Whether the given episode should be transcribed even if it looks like no
    /// speech (user override).
    public func isForced(guid: String) -> Bool {
        defaults.bool(forKey: key(guid))
    }

    /// Mark `guid` to be force-transcribed on its next run.
    public func setForced(guid: String) {
        defaults.set(true, forKey: key(guid))
    }

    /// Clear the flag (called by the Pipeline after consuming it — one-shot).
    public func clear(guid: String) {
        defaults.removeObject(forKey: key(guid))
    }
}
