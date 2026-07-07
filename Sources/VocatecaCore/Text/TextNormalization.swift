import Foundation

/// Oracle-locked ports of `core/sanitize.py` and `core/dedupe.py`.
///
/// Every function must produce **byte-for-byte identical output** to the Python
/// reference implementation for all inputs in the golden fixture files at
/// `Tests/VocatecaCoreTests/Fixtures/oracle/`.
///
/// Do NOT change these algorithms without regenerating the golden fixtures and
/// running `swift test --filter OracleTextTests`.
public enum TextNormalization: Sendable {

    // MARK: - safePathSegment

    /// Sanitizes a string for use as a SINGLE filesystem path segment WITHOUT
    /// lowercasing — so it preserves case-significant identifiers (e.g. Instagram
    /// base-62 shortcodes, where `Cxyz` ≠ `cxyz`). Keeps only ASCII letters,
    /// digits, `_` and `-`; every other character (including `/`, `.`, and
    /// whitespace) is dropped, so `..` and path separators cannot survive →
    /// no path traversal. Returns `"_"` if nothing remains.
    ///
    /// Use this (not `slugify`) for attacker-influenced path segments that must
    /// keep their exact case/identity.
    public static func safePathSegment(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let filtered = String(s.filter { allowed.contains($0) })
        return filtered.isEmpty ? "_" : filtered
    }

    // MARK: - slugify

    /// Converts a podcast title into a URL-safe ASCII slug.
    ///
    /// Port of `slugify(title)` from `core/sanitize.py`:
    /// 1. NFKD-normalise (decompose with compatibility mapping).
    /// 2. Drop every non-ASCII byte (encode ascii ignore).
    /// 3. Lowercase.
    /// 4. Replace runs of `[^a-z0-9]` with `"-"`, strip leading/trailing `"-"`.
    /// 5. Return `"show"` if the result is empty.
    public static func slugify(_ title: String) -> String {
        // Step 1: NFKD — decomposedStringWithCompatibilityMapping
        let normalised = title.decomposedStringWithCompatibilityMapping

        // Step 2: keep only ASCII scalars
        var asciiOnly = ""
        for scalar in normalised.unicodeScalars where scalar.isASCII {
            asciiOnly.unicodeScalars.append(scalar)
        }

        // Step 3: lowercase
        let lowered = asciiOnly.lowercased()

        // Step 4: replace runs of non-[a-z0-9] with "-", strip leading/trailing "-"
        guard let regex = try? NSRegularExpression(pattern: "[^a-z0-9]+") else {
            return "show"
        }
        let nsLowered = lowered as NSString
        let range = NSRange(location: 0, length: nsLowered.length)
        let collapsed = regex.stringByReplacingMatches(
            in: lowered,
            range: range,
            withTemplate: "-"
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Step 5: fallback
        return trimmed.isEmpty ? "show" : trimmed
    }

    // MARK: - sanitizeFilename

    /// Makes a string safe to use as a filename.
    ///
    /// Port of `sanitize_filename(name, max_bytes=200)` from `core/sanitize.py`:
    /// 1. NFC-normalise.
    /// 2. Remove forbidden chars: `/ \ : * ? " < > |`
    /// 3. Remove control chars U+0000–U+001F and U+007F.
    /// 4. Replace `".."` with `"."` (single left-to-right non-overlapping pass).
    /// 5. Collapse Unicode whitespace runs to a single space.
    /// 6. Strip leading/trailing spaces and dots.
    /// 7. Truncate to `maxBytes` UTF-8 bytes, drop trailing partial scalar, rstrip.
    /// 8. Return `"_"` if empty at any point.
    public static func sanitizeFilename(_ name: String, maxBytes: Int = 200) -> String {
        guard !name.isEmpty else { return "_" }

        // Step 1: NFC
        var s = name.precomposedStringWithCanonicalMapping

        // Step 2: remove forbidden chars /\:*?"<>|
        // Use a character set for speed.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        s = s.components(separatedBy: forbidden).joined()

        // Step 3: remove control chars \x00-\x1f and \x7f
        var cleaned = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F {
                continue  // drop
            }
            cleaned.unicodeScalars.append(scalar)
        }
        s = cleaned

        // Step 4: replace ".." with "." — single left-to-right non-overlapping pass
        // Swift's replacingOccurrences is non-overlapping left-to-right, matching Python.
        s = s.replacingOccurrences(of: "..", with: ".")

        // Step 5: collapse whitespace runs to a single space, matching Python's
        // `re.sub(r"\s+", " ", s)`. We use an explicit CPython-`\s` predicate
        // rather than ICU/NSRegex `\s` or CharacterSet.whitespacesAndNewlines —
        // those disagree with Python on chars like U+0085 (NEL: Python yes,
        // ICU no) and U+200B (both Apple sets wrongly say yes). Verified by the
        // oracle goldens.
        var collapsed = ""
        collapsed.reserveCapacity(s.unicodeScalars.count)
        var inSpaceRun = false
        for scalar in s.unicodeScalars {
            if Self.isPythonSpaceScalar(scalar) {
                if !inSpaceRun {
                    collapsed.unicodeScalars.append(" ")
                    inSpaceRun = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                inSpaceRun = false
            }
        }
        s = collapsed

        // Step 6: strip leading/trailing spaces and dots
        let spaceAndDot = CharacterSet(charactersIn: " .")
        s = s.trimmingCharacters(in: spaceAndDot)

        if s.isEmpty { return "_" }

        // Step 7: truncate to maxBytes UTF-8 bytes, matching Python's
        // `encoded[:max_bytes].decode("utf-8", errors="ignore").rstrip()`.
        // Since `s` is valid UTF-8 here, a cut can only ever split a trailing
        // multi-byte scalar; shrinking to the longest decodable prefix drops
        // exactly that partial scalar (the `errors="ignore"` behaviour).
        let utf8 = Array(s.utf8)
        if utf8.count > maxBytes {
            var end = maxBytes
            var decoded = ""
            while end > 0 {
                if let str = String(bytes: utf8[0..<end], encoding: .utf8) {
                    decoded = str
                    break
                }
                end -= 1
            }
            // Python str.rstrip() removes all trailing (CPython) whitespace.
            while let last = decoded.unicodeScalars.last,
                  Self.isPythonSpaceScalar(last) {
                decoded.unicodeScalars.removeLast()
            }
            s = decoded
        }

        return s.isEmpty ? "_" : s
    }

    // MARK: - normalizeTitle

    /// Normalises a podcast title for duplicate-detection comparisons.
    ///
    /// Port of `normalize_title(title)` from `core/dedupe.py`:
    /// 1. Lowercase.
    /// 2. Replace every non-`(\w|\s)` character (Unicode-aware `\w`) with a space.
    /// 3. Collapse whitespace runs, strip, split on space.
    /// 4. Drop empty tokens and tokens in the stop-word list.
    /// 5. Rejoin with single space.
    ///
    /// Uses scalar-level `generalCategory` inspection to match Python's `re.UNICODE`
    /// definition of `\w` exactly: Unicode letters (L*), decimal/letter/other numbers
    /// (N*), and connector punctuation (Pc = underscore). This correctly excludes
    /// variation selectors (Mn / nonspacingMark) which `NSRegularExpression` and
    /// `CharacterSet.alphanumerics` would incorrectly retain.
    public static func normalizeTitle(_ title: String) -> String {
        // Python's `_NOISE.sub(" ", t)` (replace every non-(\w|\s) with space)
        // followed by `\s+`-split is *exactly equivalent* to tokenising on
        // maximal runs of Python `\w` characters: both whitespace AND noise
        // become token boundaries, and word chars are the only thing kept.
        // Reducing to a single word-predicate avoids any whitespace-set
        // mismatch (e.g. CharacterSet.whitespacesAndNewlines wrongly includes
        // U+200B, which Python's `\s` does not — caught by the oracle goldens).
        let lowered = title.lowercased()

        var tokens: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if Self.isPythonWordScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }

        let dropWords: Set<String> = [
            "reupload", "re", "upload",
            "und", "and", "the",
            "der", "die", "das",
            "a", "an"
        ]
        return tokens.filter { !dropWords.contains($0) }.joined(separator: " ")
    }

    // MARK: - Private helpers

    /// Returns `true` iff `scalar` matches Python's `re.UNICODE` `\w` class:
    /// Unicode letters (L*), numbers (N*), and connector punctuation (Pc).
    ///
    /// Explicitly excludes nonspacing marks (Mn) and variation selectors such as
    /// U+FE0F, which `CharacterSet.alphanumerics` and `NSRegularExpression`'s `\w`
    /// incorrectly include on Apple platforms.
    private static func isPythonWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,      // \p{L}
             .decimalNumber,                      // \p{Nd}
             .letterNumber, .otherNumber,         // \p{Nl}, \p{No}
             .connectorPunctuation:               // \p{Pc} — includes underscore
            return true
        default:
            return false
        }
    }

    /// Returns `true` iff `scalar` is whitespace under CPython's definition
    /// (`str.isspace()` / regex `\s` in Unicode mode). This set deliberately
    /// differs from `CharacterSet.whitespacesAndNewlines` (which includes
    /// U+200B) and from ICU/NSRegex `\s` (which omits U+0085 and the
    /// U+001C–U+001F information separators).
    private static func isPythonSpaceScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D,          // TAB, LF, VT, FF, CR
             0x1C...0x1F,          // FS, GS, RS, US (information separators)
             0x20,                 // SPACE
             0x85,                 // NEL
             0xA0,                 // NO-BREAK SPACE
             0x1680,               // OGHAM SPACE MARK
             0x2000...0x200A,      // EN QUAD … HAIR SPACE
             0x2028, 0x2029,       // LINE / PARAGRAPH SEPARATOR
             0x202F,               // NARROW NO-BREAK SPACE
             0x205F,               // MEDIUM MATHEMATICAL SPACE
             0x3000:               // IDEOGRAPHIC SPACE
            return true
        default:
            return false
        }
    }
}
