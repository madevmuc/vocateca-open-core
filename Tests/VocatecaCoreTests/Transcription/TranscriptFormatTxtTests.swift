import XCTest
@testable import VocatecaCore

// MARK: - TranscriptFormatTxtTests

/// Tests for ``TranscriptFormat/txtFromMarkdown(_:)`` — the `.txt` transcript
/// export format (`vocateca-cli library export --format txt`).
///
/// `.txt` has no independent writer/sidecar on disk (unlike `.srt`/`.html`,
/// which are written at transcribe time — see ``SRTBuilderTests`` and
/// ``TranscriptFormatHTMLTests``): it is always synthesized on export from the
/// `.md` transcript by stripping YAML frontmatter and markdown heading/quote
/// lines. This function was extracted from a `private` CLI helper
/// (`LibraryCommands.synthesizeTxt(fromMarkdown:)` in
/// `Sources/vocateca-cli/Commands/Library.swift`) into `VocatecaCore` so it is
/// testable without `@testable import`-ing an executable target.
final class TranscriptFormatTxtTests: XCTestCase {

    /// A representative fixture transcript: YAML frontmatter + a banner +
    /// heading + blockquote + body paragraphs, matching what
    /// `MarkdownLibraryWriter` actually produces.
    private let fixtureMarkdown = """
    ---
    title: "Test Episode"
    show: test-show
    pubDate: 2026-07-01
    transcript_origin: "asr:parakeet:tdt-0.6b-v3"
    ---

    # Test Episode

    > [!info] Episode vom 2026-07-01 (vor 3 Tagen)

    This is the first line of dialogue.

    This is the second line, with some more content.

    Final line of the transcript.
    """

    // MARK: - Frontmatter stripped

    func testFrontmatterBlockIsStripped() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        XCTAssertFalse(txt.contains("title:"), "YAML frontmatter must be stripped")
        XCTAssertFalse(txt.contains("transcript_origin"), "YAML frontmatter must be stripped")
        XCTAssertFalse(txt.contains("---"), "frontmatter delimiters must be stripped")
    }

    // MARK: - Headings and blockquotes stripped

    func testHeadingLinesAreStripped() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        XCTAssertFalse(txt.contains("# Test Episode"), "markdown heading lines must be dropped")
    }

    func testBlockquoteLinesAreStripped() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        XCTAssertFalse(txt.contains("[!info]"), "blockquote/callout lines must be dropped")
    }

    // MARK: - Body preserved

    func testBodyParagraphsArePreserved() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        XCTAssertTrue(txt.contains("This is the first line of dialogue."))
        XCTAssertTrue(txt.contains("This is the second line, with some more content."))
        XCTAssertTrue(txt.contains("Final line of the transcript."))
    }

    func testOutputEndsWithTrailingNewline() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        XCTAssertTrue(txt.hasSuffix("\n"))
    }

    // MARK: - Blank lines dropped entirely (not preserved as paragraph breaks)

    func testBlankLinesAreDropped() {
        let txt = TranscriptFormat.txtFromMarkdown(fixtureMarkdown)
        // Drop the one *trailing* empty element produced by the final "\n"
        // (the function always appends exactly one trailing newline) — no
        // OTHER blank line should survive.
        var lines = txt.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "", "output must end with exactly one trailing newline")
        lines.removeLast()
        XCTAssertFalse(lines.contains(""), "no blank lines should survive besides the trailing newline")
    }

    // MARK: - No frontmatter at all (already-plain markdown)

    func testNoFrontmatterPassesThroughBodyRules() {
        let md = "# Heading\n\n> quote\n\nJust a line of text.\n"
        let txt = TranscriptFormat.txtFromMarkdown(md)
        XCTAssertEqual(txt, "Just a line of text.\n")
    }

    // MARK: - Empty input

    func testEmptyInputProducesJustNewline() {
        XCTAssertEqual(TranscriptFormat.txtFromMarkdown(""), "\n")
    }

    // MARK: - Whitespace-only lines are trimmed then dropped

    func testWhitespaceOnlyLinesDropped() {
        let md = "line one\n   \nline two\n"
        let txt = TranscriptFormat.txtFromMarkdown(md)
        XCTAssertEqual(txt, "line one\nline two\n")
    }

    // MARK: - Leading/trailing whitespace trimmed per-line

    func testPerLineWhitespaceTrimmed() {
        let md = "   indented line   \n\tanother\t\n"
        let txt = TranscriptFormat.txtFromMarkdown(md)
        XCTAssertEqual(txt, "indented line\nanother\n")
    }

    // MARK: - Full fixture snapshot (golden-style, guards against silent drift)

    func testFullFixtureSnapshot() {
        let expected = """
        This is the first line of dialogue.
        This is the second line, with some more content.
        Final line of the transcript.

        """
        XCTAssertEqual(TranscriptFormat.txtFromMarkdown(fixtureMarkdown), expected)
    }
}
