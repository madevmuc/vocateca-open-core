import Foundation
import GRDB

// MARK: - TranscriptHit

/// One full-text-search hit against the `transcripts_fts` index.
///
/// `snippet` is the FTS5 `snippet()` output: a short excerpt of the matching
/// `content` with the query terms wrapped in the match markers (see
/// ``StateStore/ftsSnippetOpenMarker`` / ``ftsSnippetCloseMarker``) and elided
/// context replaced by ``ftsSnippetEllipsis``. The UI parses those markers to
/// render the highlight; the rest of the app treats `snippet` as plain text.
public struct TranscriptHit: Sendable, Equatable, Identifiable {
    /// Episode GUID — routes the hit back to the episode (open transcript, etc.).
    public let guid: String
    /// Show slug the episode belongs to.
    public let showSlug: String
    /// Episode title (indexed copy — may lag a later rename until re-indexed).
    public let title: String
    /// `snippet()` excerpt with match markers + ellipsis (see type doc).
    public let snippet: String

    /// Stable identity for SwiftUI `ForEach` — the guid uniquely identifies the
    /// hit (one FTS row per episode).
    public var id: String { guid }

    public init(guid: String, showSlug: String, title: String, snippet: String) {
        self.guid = guid
        self.showSlug = showSlug
        self.title = title
        self.snippet = snippet
    }
}

public extension StateStore {

    // MARK: - Snippet markers

    /// Opening marker FTS5 `snippet()` wraps around a matched term. Chosen to be a
    /// string that never occurs in real transcript text so the UI can split on it
    /// unambiguously.
    static let ftsSnippetOpenMarker = "\u{2060}[["
    /// Closing marker (see ``ftsSnippetOpenMarker``).
    static let ftsSnippetCloseMarker = "]]\u{2060}"
    /// Ellipsis FTS5 inserts for elided context.
    static let ftsSnippetEllipsis = "…"

    // MARK: - Write hook (index / upsert)

    /// Indexes (or re-indexes) one finished transcript into `transcripts_fts`.
    ///
    /// Upsert-by-guid: FTS5 has no unique constraint, so this deletes any existing
    /// row for `guid` and inserts the fresh title + content in one transaction —
    /// re-transcribing or re-indexing never leaves a stale duplicate. `content`
    /// must already be **plain text** (strip markdown/SRT cue syntax before
    /// calling — see ``TranscriptFormat/srtToPlainText`` /
    /// ``TranscriptFormat/txtFromMarkdown``).
    ///
    /// Best-effort at the call site: the pipeline logs and continues on failure so
    /// a busy DB never fails an otherwise-complete transcript (search is a
    /// convenience layer, not the transcript itself). The one-time backfill picks
    /// up anything a transient failure here skipped.
    func indexTranscript(guid: String, showSlug: String, title: String, content: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE guid = ?", arguments: [guid])
            try db.execute(
                sql: """
                    INSERT INTO transcripts_fts (guid, show_slug, title, content)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [guid, showSlug, title, content]
            )
        }
    }

    // MARK: - Deletion hooks

    /// Removes the FTS row for a single episode (transcript delete). Idempotent —
    /// deleting a guid with no indexed row is a no-op.
    func removeTranscriptFromIndex(guid: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE guid = ?", arguments: [guid])
        }
    }

    /// Removes every FTS row for a show (show delete). Called from
    /// ``deleteShow(slug:)`` so the search index never surfaces hits for an
    /// unsubscribed show whose transcripts were removed from disk.
    func removeTranscriptsFromIndex(showSlug: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE show_slug = ?", arguments: [showSlug])
        }
    }

    // MARK: - Query API

    /// Full-text search over indexed transcript content + titles.
    ///
    /// The raw `query` string is sanitised into a safe FTS5 MATCH expression via
    /// ``makeFTSMatchExpression(_:)`` (each token quoted; the last token gets a
    /// `*` prefix-match so typing "steuer" already finds "steuererklärung").
    /// Results are ranked by FTS5 `rank` (best first) and capped at `limit`.
    ///
    /// - Returns: `[]` for an empty/whitespace-only query or a query with no
    ///   indexable tokens. Never throws for a malformed user string — the
    ///   sanitiser guarantees a valid MATCH expression; a genuine DB error
    ///   (e.g. the table missing on a broken DB) still propagates.
    func searchTranscripts(_ query: String, limit: Int = 100) throws -> [TranscriptHit] {
        guard let match = Self.makeFTSMatchExpression(query) else { return [] }
        let open = Self.ftsSnippetOpenMarker
        let close = Self.ftsSnippetCloseMarker
        let ellipsis = Self.ftsSnippetEllipsis
        return try dbQueue.read { db in
            // snippet(<table>, <col>, <open>, <close>, <ellipsis>, <tokens>)
            //   col 3 = `content`; ~12 tokens of context around the match.
            try Row.fetchAll(
                db,
                sql: """
                    SELECT guid, show_slug, title,
                           snippet(transcripts_fts, 3, ?, ?, ?, 12) AS snip
                    FROM transcripts_fts
                    WHERE transcripts_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """,
                arguments: [open, close, ellipsis, match, limit]
            ).map { row in
                TranscriptHit(
                    guid: row["guid"],
                    showSlug: row["show_slug"],
                    title: row["title"],
                    snippet: row["snip"] ?? ""
                )
            }
        }
    }

    // MARK: - FTS MATCH sanitiser

    /// Turns an arbitrary user string into a safe FTS5 MATCH expression, or `nil`
    /// when there is nothing to search for.
    ///
    /// FTS5 MATCH has its own query syntax (`AND`/`OR`/`NEAR`/`"`/`*`/`(`/`:` …).
    /// Passing raw user input straight to MATCH both risks a syntax error (an
    /// unbalanced quote throws) and lets a stray `OR`/column-filter change the
    /// query's meaning. Instead:
    ///   1. Split on whitespace.
    ///   2. Strip every double-quote from each token (so a token can't break out
    ///      of the phrase quoting) and drop tokens that become empty.
    ///   3. Wrap each token in double quotes → an FTS5 "string" (a literal term,
    ///      immune to operator interpretation).
    ///   4. Give the LAST token a trailing `*` (prefix match) so a query is
    ///      responsive as the user is still typing the final word.
    ///   5. Join with a space → implicit AND (all terms must appear).
    ///
    /// Example: `Bär OR "x` → `"Bär" "OR" "x"*` (the `OR` is a literal term, not
    /// the FTS operator; the dangling quote is gone).
    static func makeFTSMatchExpression(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var parts: [String] = []
        for (i, token) in tokens.enumerated() {
            let isLast = i == tokens.count - 1
            // Quote the term; add a prefix `*` OUTSIDE the closing quote for the
            // last token (FTS5 prefix syntax is `"term"*`).
            parts.append(isLast ? "\"\(token)\"*" : "\"\(token)\"")
        }
        return parts.joined(separator: " ")
    }
}
