import Foundation

/// One-URL-per-line (or first-CSV-column) parser for Local Ingest's `.csv`
/// import path. Not a general CSV parser — deliberately simple: splits each
/// line on the first comma, trims whitespace/quotes, skips blank lines and
/// `#`-prefixed comments. Does not classify or validate URLs; that's
/// `OneOffLinkClassifier`'s job downstream.
public enum CSVLinkList {
    public static func parse(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> String? in
                let firstField = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init) ?? line
                let cleaned = firstField
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
    }
}
