import Foundation

/// Lightweight update channel — the notarization-free MVP step from the freemium
/// hand-over §8 ("Releases-Notify: Versions-Check + Download-Hinweis").
///
/// The full **Sparkle** in-place updater (signed appcast + delta updates) is
/// coupled to code-signing/notarization and is a **launch** step (not part of
/// "done"). This type provides the interim mechanism: compare the running version
/// against the latest GitHub release and surface a download hint. The version
/// comparison is pure + deterministic; the network fetch is size-capped and
/// SSRF-guarded via `URLSafety`.
public struct UpdateChecker: Sendable {

    public struct UpdateInfo: Sendable, Equatable {
        public let latestVersion: String
        public let currentVersion: String
        public let isUpdateAvailable: Bool
        public let releaseURL: String
    }

    public let repo: String          // e.g. "madevmuc/vocateca"
    public let currentVersion: String

    public init(repo: String = "madevmuc/vocateca", currentVersion: String = Vocateca.version) {
        self.repo = repo
        self.currentVersion = currentVersion
    }

    /// Fetches the latest release tag from the GitHub API and compares it to the
    /// running version. Network errors propagate (callers treat a failure as
    /// "no update info", never blocking the app — same fail-open spirit as the
    /// entitlement check).
    public func checkForUpdate(session: URLSession = .shared) async throws -> UpdateInfo {
        let api = "https://api.github.com/repos/\(repo)/releases/latest"
        _ = try URLSafety.safeURL(api)
        guard let apiURL = URL(string: api) else { throw URLSafetyError.empty }
        let data = try await URLSafety.boundedData(
            from: apiURL, maxBytes: 1_000_000, timeout: 15, session: session
        )
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tag = (obj?["tag_name"] as? String) ?? ""
        let htmlURL = (obj?["html_url"] as? String) ?? "https://github.com/\(repo)/releases"
        let latest = Self.normalizeTag(tag)
        return UpdateInfo(
            latestVersion: latest,
            currentVersion: currentVersion,
            isUpdateAvailable: Self.compare(latest, isNewerThan: currentVersion),
            releaseURL: htmlURL
        )
    }

    // MARK: - Pure version logic (oracle-testable)

    /// Strips a leading `v`/`V` and surrounding whitespace from a release tag.
    public static func normalizeTag(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        return s
    }

    /// Semantic-version comparison: returns `true` iff `a` is strictly newer than
    /// `b`. Compares dot-separated numeric components left-to-right; missing
    /// components count as 0 (so `2.1` == `2.1.0`). Non-numeric components compare
    /// as 0. Empty `a` is never newer.
    public static func compare(_ a: String, isNewerThan b: String) -> Bool {
        if a.isEmpty { return false }
        let pa = normalizeTag(a).split(separator: ".").map { Int($0) ?? 0 }
        let pb = normalizeTag(b).split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
