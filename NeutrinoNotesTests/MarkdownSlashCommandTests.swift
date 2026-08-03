import XCTest
@testable import NeutrinoNotes

final class MarkdownSlashCommandTests: XCTestCase {

    // MARK: - Helpers

    private func token(in text: String, caretAfter prefix: String) -> MarkdownSlashCommand.Token? {
        MarkdownSlashCommand.token(in: text as NSString, caret: (prefix as NSString).length)
    }

    private func tokenAtEnd(of text: String) -> MarkdownSlashCommand.Token? {
        MarkdownSlashCommand.token(in: text as NSString, caret: (text as NSString).length)
    }

    // MARK: - Opening

    func test_token_slashAtTheStartOfTheNote_isACommand() {
        XCTAssertEqual(tokenAtEnd(of: "/"),
                       MarkdownSlashCommand.Token(range: NSRange(location: 0, length: 1), query: ""))
    }

    func test_token_slashAtTheStartOfALine_isACommand() {
        XCTAssertEqual(tokenAtEnd(of: "Notes from today\n/"),
                       MarkdownSlashCommand.Token(range: NSRange(location: 17, length: 1), query: ""))
    }

    func test_token_carriesWhatWasTypedAfterTheSlash() {
        XCTAssertEqual(tokenAtEnd(of: "/head")?.query, "head")
        XCTAssertEqual(tokenAtEnd(of: "/head")?.range, NSRange(location: 0, length: 5))
    }

    func test_token_ignoresTextAfterTheCaretOnTheSameLine() {
        // Typing "/" at the head of a line that already has text still offers to format it.
        XCTAssertEqual(token(in: "/Buy milk", caretAfter: "/")?.query, "")
    }

    // MARK: - Not a Command

    func test_token_slashMidLine_isNotACommand() {
        XCTAssertNil(tokenAtEnd(of: "and/or"))
        XCTAssertNil(tokenAtEnd(of: "See /"))
    }

    func test_token_indentedSlash_isNotACommand() {
        // The slash has to be the first character of the line, not the first non-blank one.
        XCTAssertNil(tokenAtEnd(of: "    /"))
    }

    func test_token_slashFollowedByASpace_isNotACommand() {
        XCTAssertNil(tokenAtEnd(of: "/ "))
        XCTAssertNil(tokenAtEnd(of: "/note to self"))
    }

    func test_token_lineWithoutASlash_isNotACommand() {
        XCTAssertNil(tokenAtEnd(of: ""))
        XCTAssertNil(tokenAtEnd(of: "Buy milk"))
    }

    func test_token_caretBeforeTheSlash_isNotACommand() {
        XCTAssertNil(token(in: "/head", caretAfter: ""))
    }

    func test_token_caretOnTheLineBelow_isNotACommand() {
        XCTAssertNil(tokenAtEnd(of: "/head\n"))
    }

    func test_token_rangeBeyondTheText_isNotACommand() {
        XCTAssertNil(MarkdownSlashCommand.token(in: "/" as NSString, caret: 99))
    }

    // MARK: - Matching Formats

    func test_matching_emptyQuery_offersEverything() {
        XCTAssertEqual(MarkdownFormat.matching(""), MarkdownFormat.all)
    }

    func test_matching_narrowsByName() {
        XCTAssertEqual(MarkdownFormat.matching("bol").map(\.id), ["bold"])
        XCTAssertEqual(MarkdownFormat.matching("ital").map(\.id), ["italic"])
    }

    func test_matching_isCaseInsensitive() {
        XCTAssertEqual(MarkdownFormat.matching("BOLD").map(\.id), ["bold"])
    }

    func test_matching_narrowsByKeyword() {
        XCTAssertEqual(MarkdownFormat.matching("h1").map(\.id), ["heading1"])
        XCTAssertEqual(MarkdownFormat.matching("todo").map(\.id), ["checklist"])
    }

    func test_matching_matchesAnyWordOfTheName() {
        XCTAssertEqual(MarkdownFormat.matching("list").map(\.id), ["bulletList", "numberedList", "checklist"])
    }

    func test_matching_keepsMenuOrder() {
        XCTAssertEqual(MarkdownFormat.matching("h").map(\.id).prefix(3), ["heading1", "heading2", "heading3"])
    }

    func test_matching_nothingMatches_isEmpty() {
        XCTAssertTrue(MarkdownFormat.matching("zzz").isEmpty)
        XCTAssertTrue(MarkdownFormat.matching("usr").isEmpty, "a note containing a path must not open a menu")
    }

    // MARK: - Snippets

    func test_everyFormat_putsTheCaretInsideItsSnippet() {
        for format in MarkdownFormat.all {
            XCTAssertLessThanOrEqual(format.caretOffset, (format.snippet as NSString).length,
                                     "\(format.id) would leave the caret past the end of its snippet")
            XCTAssertGreaterThan(format.caretOffset, 0, "\(format.id) would leave the caret before its snippet")
        }
    }

    func test_wrappingFormats_putTheCaretBetweenTheMarkers() {
        let bold = MarkdownFormat.all.first { $0.id == "bold" }
        XCTAssertEqual(bold?.snippet, "****")
        XCTAssertEqual(bold?.caretOffset, 2)

        let code = MarkdownFormat.all.first { $0.id == "code" }
        XCTAssertEqual(code?.snippet, "``")
        XCTAssertEqual(code?.caretOffset, 1)
    }

    func test_formatIDsAreUnique() {
        XCTAssertEqual(Set(MarkdownFormat.all.map(\.id)).count, MarkdownFormat.all.count)
    }
}
