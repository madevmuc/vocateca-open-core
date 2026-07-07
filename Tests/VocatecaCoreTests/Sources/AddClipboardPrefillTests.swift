import XCTest
@testable import VocatecaCore

// MARK: - AddClipboardPrefillTests

/// Table-driven coverage for ``AddClipboardPrefill/shouldPrefill(clipboard:lastAdded:)``
/// — the pure "seed the Add router's fast-path field from the clipboard?"
/// decision (brief-add-one-door.md §2), including the repeat-suppression rule
/// (never re-nag with a value already added this session).
///
/// Pure/network-free: no `NSPasteboard` here — `AddRouterSheet` is the only
/// place that reads the real pasteboard (see its `.onAppear`), and it does so
/// exactly once, on sheet open.
final class AddClipboardPrefillTests: XCTestCase {

    // MARK: - Table

    private struct Case {
        let clipboard: String?
        let lastAdded: String?
        let expected: Bool
        let name: String
    }

    private let table: [Case] = [
        // Nil / empty / whitespace clipboard → never prefill.
        Case(clipboard: nil, lastAdded: nil, expected: false, name: "nil clipboard"),
        Case(clipboard: "", lastAdded: nil, expected: false, name: "empty clipboard"),
        Case(clipboard: "   ", lastAdded: nil, expected: false, name: "whitespace-only clipboard"),

        // Unrecognised content (classifies as .none only for empty/whitespace —
        // everything else classifies as SOME kind, incl. bare search terms —
        // so this table doesn't need a separate ".none but non-empty" case;
        // AddSourceClassifier's own empty-check covers it identically).

        // Recognised content, no prior add this session → prefill.
        Case(clipboard: "https://youtube.com/@mkbhd", lastAdded: nil,
             expected: true, name: "youtube channel, no prior add"),
        Case(clipboard: "@natgeo", lastAdded: nil,
             expected: true, name: "instagram handle, no prior add"),
        Case(clipboard: "https://feeds.example.com/show.xml", lastAdded: nil,
             expected: true, name: "podcast RSS, no prior add"),
        Case(clipboard: "huberman lab", lastAdded: nil,
             expected: true, name: "bare search term, no prior add"),
        Case(clipboard: "https://soundcloud.com/foo/bar", lastAdded: nil,
             expected: true, name: "generic yt-dlp URL, no prior add"),

        // Repeat suppression: clipboard == lastAdded (exact, post-trim) → suppress.
        Case(clipboard: "https://youtube.com/@mkbhd", lastAdded: "https://youtube.com/@mkbhd",
             expected: false, name: "exact repeat of last-added value"),
        Case(clipboard: "  https://youtube.com/@mkbhd  ", lastAdded: "https://youtube.com/@mkbhd",
             expected: false, name: "repeat with surrounding whitespace on clipboard side"),
        Case(clipboard: "https://youtube.com/@mkbhd", lastAdded: "  https://youtube.com/@mkbhd  ",
             expected: false, name: "repeat with surrounding whitespace on lastAdded side"),

        // Different value from lastAdded → still prefill (suppression is exact-match only).
        Case(clipboard: "@natgeo", lastAdded: "https://youtube.com/@mkbhd",
             expected: true, name: "different value than last-added"),
        Case(clipboard: "https://youtube.com/@mkbhd", lastAdded: "@natgeo",
             expected: true, name: "different value, order swapped"),
    ]

    func testPrefillDecisionTable() {
        for c in table {
            XCTAssertEqual(
                AddClipboardPrefill.shouldPrefill(clipboard: c.clipboard, lastAdded: c.lastAdded),
                c.expected,
                "case '\(c.name)' (clipboard=\(c.clipboard ?? "nil"), lastAdded=\(c.lastAdded ?? "nil")) expected \(c.expected)"
            )
        }
    }

    // MARK: - Case sensitivity / exactness of the repeat-suppression match

    func testRepeatSuppressionIsCaseSensitive() {
        // A differently-cased repeat is NOT suppressed — exact match only, no
        // normalisation beyond whitespace trimming (mirrors AddSourceClassifier's
        // own lack of case-folding, see its "quirk" tests).
        XCTAssertTrue(
            AddClipboardPrefill.shouldPrefill(clipboard: "@NatGeo", lastAdded: "@natgeo")
        )
    }

    func testRepeatSuppressionOnlyAppliesToTheImmediatelyRelevantValue() {
        // lastAdded tracks a single most-recent value (per brief §2: "a
        // last-prefilled/last-added memo"), not a history — a value added TWO
        // adds ago is treated as "new" again once a different one supersedes it.
        // (This is a documentation-only assertion: the memo itself is owned by
        // the view's @State, not this pure function — nothing to call here
        // beyond confirming a fresh nil after supersession behaves like "no
        // prior add".)
        XCTAssertTrue(
            AddClipboardPrefill.shouldPrefill(clipboard: "https://feeds.example.com/show.xml", lastAdded: nil)
        )
    }
}
