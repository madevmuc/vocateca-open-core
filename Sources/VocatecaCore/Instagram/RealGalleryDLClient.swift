import Foundation

// MARK: - RealGalleryDLClient

/// A `GalleryDLClient` backed by the `gallery-dl` subprocess.
///
/// ## Exact gallery-dl invocation
///
/// ```
/// gallery-dl --dump-json [--cookies <path>] -- https://www.instagram.com/<profile>/
/// ```
///
/// - `--dump-json` (alias `-j`): dumps all metadata as JSON to stdout **without**
///   downloading any files. Each extracted item is output as a JSON array with three
///   elements: `[<type-int>, <url-string>, <metadata-dict>]` where
///   `type-int == 2` denotes a media item (type 0 is an extractor message, type 1
///   is a queue entry). The full dump is a **JSON array of these triples**.
///
/// ## Expected output shape
///
/// gallery-dl's `--dump-json` emits a JSON array at the top level, one element per
/// extracted item. Each element is a 3-element JSON array:
///
/// ```json
/// [
///   [2, "https://cdn.instagram.com/…/photo.jpg", {
///     "shortcode": "CxYzABCD",
///     "description": "caption text…",
///     "date": "2024-03-15T10:30:00",
///     "typename": "GraphImage",
///     "filename": "post_CxYzABCD",
///     "extension": "jpg",
///     "post_url": "https://www.instagram.com/p/CxYzABCD/"
///   }],
///   …
/// ]
/// ```
///
/// **Field mapping to `GalleryDLItem`:**
/// | gallery-dl metadata key | GalleryDLItem field |
/// |-------------------------|---------------------|
/// | *(element[1])*          | `url`               |
/// | `filename` + `extension`| `filename`          |
/// | `shortcode`             | `shortcode`         |
/// | `description`           | `caption`           |
/// | `date` (ISO 8601, no Z) | `timestamp`         |
/// | `typename` or `__typename`| `mediaType` (`"image"` or `"video"`) |
///
/// **typename → mediaType mapping:**
/// - `GraphImage`, `XDTGraphImage` → `"image"`
/// - `GraphVideo`, `XDTGraphVideo`, `GraphReel` → `"video"`
/// - anything else → `nil`
///
/// Items with `type-int != 2` are silently skipped (they are extractor/queue
/// messages, not media items).
///
/// ## Cookie-auth
///
/// Instagram requires authentication to enumerate profile media reliably. Pass
/// `cookiesPath` to provide a Netscape-format cookie file (gallery-dl `--cookies`).
/// Keychain storage of the cookie path is a later phase; this client accepts the
/// path directly.
///
/// ## MockGalleryDLClient compatibility
///
/// `MockGalleryDLClient` uses a simplified JSON format (a flat array of
/// `GalleryDLItem`-shaped objects) for fixture clarity. `RealGalleryDLClient`
/// parses the native gallery-dl 3-tuple format described above. Both produce
/// `[GalleryDLItem]`. This divergence is intentional: the mock format is easier to
/// hand-author, while the real format matches gallery-dl's actual output.
///
/// Tests for command construction use the pure `buildArguments(profile:cookiesPath:)`
/// helper and never invoke the subprocess.
public struct RealGalleryDLClient: GalleryDLClient {

    // MARK: - Properties

    private let binaryManager: BinaryManager
    private let subprocess: Subprocess
    /// Optional path to a Netscape-format cookies file for authenticated requests.
    public let cookiesPath: URL?

    // MARK: - Init

    public init(
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        cookiesPath: URL? = nil
    ) {
        self.binaryManager = binaryManager
        self.subprocess = subprocess
        self.cookiesPath = cookiesPath
    }

    // MARK: - GalleryDLClient

    /// Enumerates items for `profile` (Instagram username/handle, **without** `@`)
    /// by running gallery-dl with `--dump-json` and parsing the JSON output.
    ///
    /// Items are returned in gallery-dl's natural order (newest-first for Instagram).
    ///
    /// - Throws: `GalleryDLClientError.binaryNotFound` if gallery-dl is not installed.
    ///   `GalleryDLClientError.subprocessFailed` on non-zero exit.
    ///   `GalleryDLClientError.outputParsingFailed` on JSON decode errors.
    public func enumerate(profile: String) async throws -> [GalleryDLItem] {
        guard let binaryURL = binaryManager.resolvedPath(for: .galleryDL) else {
            throw GalleryDLClientError.binaryNotFound
        }
        let args = Self.buildArguments(profile: profile, cookiesPath: cookiesPath)
        let result = try await subprocess.run(binaryURL, args, timeout: 120)
        guard result.exitCode == 0 else {
            throw GalleryDLClientError.subprocessFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return try Self.parse(jsonOutput: result.stdout)
    }

    // MARK: - Pure command construction (testable without IO)

    /// Returns the argument array for a `gallery-dl --dump-json` invocation.
    ///
    /// This is a pure function with no IO, making it unit-testable without
    /// running the subprocess.
    ///
    /// - Parameters:
    ///   - profile: Instagram handle (without `@`).
    ///   - cookiesPath: Optional Netscape cookies file path.
    /// - Returns: The `args` array to pass to `Subprocess.run`.
    public static func buildArguments(profile: String, cookiesPath: URL?) -> [String] {
        // L-3: --ignore-config skips gallery-dl's own config-file discovery
        // (which would otherwise honour a same-user-writable config).
        var args: [String] = GalleryDL.hardenedBaseArgs + ["--dump-json"]
        if let cookies = cookiesPath {
            args += ["--cookies", cookies.path]
        }
        // Use `--` to terminate options before the URL (in case profile starts with `-`).
        args += ["--", "https://www.instagram.com/\(profile)/"]
        return args
    }

    // MARK: - JSON parsing (pure — testable without IO)

    /// Parses gallery-dl's `--dump-json` output (a JSON array of 3-tuples) into
    /// `[GalleryDLItem]`.
    ///
    /// Items where `element[0] != 2` are skipped (not media items). Items missing
    /// both `shortcode` and `filename` metadata are also skipped as malformed.
    ///
    /// - Throws: `GalleryDLClientError.outputParsingFailed` on JSON decode failure.
    public static func parse(jsonOutput: String) throws -> [GalleryDLItem] {
        guard let data = jsonOutput.data(using: .utf8) else {
            throw GalleryDLClientError.outputParsingFailed("Output is not valid UTF-8")
        }
        // Top-level: array of triples.
        guard let topLevel = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw GalleryDLClientError.outputParsingFailed(
                "Expected a JSON array of arrays at top level; got something else"
            )
        }

        var items: [GalleryDLItem] = []
        for triple in topLevel {
            // Each element is [type-int, url-string, metadata-dict]
            guard triple.count >= 1,
                  let typeInt = triple[0] as? Int,
                  typeInt == 2                        // 2 = media item
            else { continue }

            guard triple.count >= 3,
                  let urlString = triple[1] as? String,
                  let meta = triple[2] as? [String: Any]
            else { continue }

            let shortcode  = meta["shortcode"] as? String
            let caption    = meta["description"] as? String

            // Reconstruct filename from meta["filename"] + meta["extension"].
            let baseName   = meta["filename"] as? String ?? ""
            let ext        = meta["extension"] as? String ?? ""
            let filename   = ext.isEmpty ? baseName : "\(baseName).\(ext)"

            // Parse date. gallery-dl emits ISO-8601 without trailing Z:
            // "2024-03-15T10:30:00"
            let timestamp: Date?
            if let dateStr = meta["date"] as? String {
                timestamp = Self.parseGalleryDLDate(dateStr)
            } else {
                timestamp = nil
            }

            // Determine mediaType from typename.
            let typename  = (meta["typename"] as? String)
                         ?? (meta["__typename"] as? String)
                         ?? ""
            let mediaType = Self.mediaType(from: typename)

            items.append(GalleryDLItem(
                url:       urlString,
                filename:  filename,
                shortcode: shortcode,
                caption:   caption,
                timestamp: timestamp,
                mediaType: mediaType
            ))
        }
        return items
    }

    // MARK: - Private helpers

    /// Maps gallery-dl `typename` values to `"image"` or `"video"`.
    static func mediaType(from typename: String) -> String? {
        switch typename {
        case "GraphImage", "XDTGraphImage":
            return "image"
        case "GraphVideo", "XDTGraphVideo", "GraphReel", "XDTGraphReel":
            return "video"
        default:
            return nil
        }
    }

    /// Parses a gallery-dl date string (ISO 8601, no trailing Z or offset).
    ///
    /// gallery-dl emits dates as `"2024-03-15T10:30:00"` (local time of the
    /// server, effectively UTC for Instagram). We treat them as UTC.
    static func parseGalleryDLDate(_ s: String) -> Date? {
        // Try the standard no-Z ISO 8601 form first.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: s + "Z") { return d }
        // Fallback: try as-is (in case gallery-dl adds the Z in a future version).
        if let d = formatter.date(from: s) { return d }
        return nil
    }
}

// MARK: - Errors

public enum GalleryDLClientError: Error, Sendable {
    case binaryNotFound
    case subprocessFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(String)
}
