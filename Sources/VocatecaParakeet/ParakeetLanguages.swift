import Foundation

/// The 25 European languages supported by parakeet-tdt-0.6b-v3 (BCP-47 base codes).
/// Anything NOT in this set must be routed to Whisper (structural, not a mis-detection).
///
/// Intentional divergence from FluidAudio: its own `Language` script-filter enum
/// (`TokenLanguageFilter.swift`) carries 28 entries — it additionally lists `bs`
/// (Bosnian), `be` (Belarusian) and `sr` (Serbian). We deliberately keep only the
/// **25** on the parakeet-tdt-0.6b-v3 model card as the authoritative "officially
/// supported" routing gate, so `bs`/`be`/`sr` sources route to Whisper. All 25 here
/// map cleanly onto FluidAudio's `Language`, so nothing that passes routing fails the
/// `fluidLanguage(from:)` hint. Revisit if NVIDIA expands the model card.
public enum ParakeetLanguages {
    public static let supported: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// True only when `bcp47` names a language Parakeet v3 can handle. `nil`
    /// (unknown language) returns `false` — the caller decides how to route
    /// unknown-language audio; this is not a claim of support.
    public static func supports(_ bcp47: String?) -> Bool {
        guard let base = normalize(bcp47) else { return false }
        return supported.contains(base)
    }

    /// Lowercased primary subtag, e.g. `"de-DE"` → `"de"`, `"EN"` → `"en"`.
    static func normalize(_ bcp47: String?) -> String? {
        guard let raw = bcp47?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.split(separator: "-").first.map { $0.lowercased() }
    }
}
