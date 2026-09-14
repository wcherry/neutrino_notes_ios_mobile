import XCTest
import NeutrinoCore
@testable import NeutrinoNotes

/// Tests for `WikiLink` — the `[[…]]` syntax three separately shipped clients have to agree on.
///
/// The first four cases are deliberate ports of `web/packages/markdown`'s tests (which are
/// themselves ports of the backend's `parse_wiki_links` tests). They are the interop contract: if
/// one of them fails here, a link written on a phone means something different from the same link
/// written in the browser.
final class WikiLinkTests: XCTestCase {

    // MARK: - Extraction (ported from web/packages/markdown)

    func test_titles_basic() {
        XCTAssertEqual(WikiLink.titles(in: "See [[Meeting Notes]] and [[Project Plan]]."),
                       ["Meeting Notes", "Project Plan"])
    }

    func test_titles_empty() {
        XCTAssertEqual(WikiLink.titles(in: "No links here at all."), [])
    }

    func test_titles_trimsWhitespace() {
        XCTAssertEqual(WikiLink.titles(in: "[[  Meeting Notes  ]]"), ["Meeting Notes"])
    }

    func test_titles_skipsEmptyBrackets() {
        XCTAssertEqual(WikiLink.titles(in: "[[]] and [[   ]] and [[Real]]"), ["Real"])
    }

    // MARK: - Extraction (iOS specifics)

    func test_titles_deduplicatesCaseInsensitively_keepingTheFirstSpelling() {
        // The server folds case when it resolves, so two spellings are one edge, not two.
        XCTAssertEqual(WikiLink.titles(in: "[[Meeting Notes]] then [[meeting notes]]"),
                       ["Meeting Notes"])
    }

    func test_titles_ignoresAnUnclosedLink() {
        XCTAssertEqual(WikiLink.titles(in: "[[Never closed"), [])
    }

    func test_matches_reportsUTF16RangesCoveringBothBrackets() {
        let matches = WikiLink.matches(in: "ab [[Note]] cd")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.range, NSRange(location: 3, length: 8))
        XCTAssertEqual(matches.first?.title, "Note")
    }

    func test_matches_rangesSurviveAnEmojiEarlierInTheLine() {
        // An emoji is two UTF-16 units and one Character; a range measured in Characters would put
        // the highlight — and the replacement — one unit to the left of the link.
        let text = "\u{1F600} [[Note]]"
        let matches = WikiLink.matches(in: text)
        XCTAssertEqual(matches.first?.range, NSRange(location: 3, length: 8))
        XCTAssertEqual((text as NSString).substring(with: matches[0].range), "[[Note]]")
    }

    // MARK: - Request Titles

    func test_requestTitles_sendsBothSpellingsSoTheWebAndTheAppResolveEachOther() {
        // This app names notes "Meeting Notes.md"; the web app names them "Meeting Notes". The
        // server matches names exactly (case aside), so only sending one spelling would leave the
        // link resolving to nothing on one of the two clients.
        XCTAssertEqual(WikiLink.requestTitles(in: "[[Meeting Notes]]"),
                       ["Meeting Notes", "Meeting Notes.md"])
    }

    func test_requestTitles_doesNotRepeatASpellingTheAuthorAlreadyTyped() {
        XCTAssertEqual(WikiLink.requestTitles(in: "[[Notes.md]] and [[Notes]]"),
                       ["Notes.md", "Notes.md.md", "Notes"])
    }

    func test_requestTitles_ofANoteWithoutLinks_isEmpty() {
        XCTAssertEqual(WikiLink.requestTitles(in: "Just prose."), [])
    }

    // MARK: - Titles and Keys

    func test_displayTitle_stripsTheExtensionThisAppAppends() {
        XCTAssertEqual(WikiLink.displayTitle(for: "Meeting Notes.md"), "Meeting Notes")
        XCTAssertEqual(WikiLink.displayTitle(for: "Meeting Notes.MD"), "Meeting Notes")
        XCTAssertEqual(WikiLink.displayTitle(for: "Meeting Notes"), "Meeting Notes")
    }

    func test_displayTitle_leavesANameThatIsOnlyAnExtensionAlone() {
        XCTAssertEqual(WikiLink.displayTitle(for: ".md"), ".md")
    }

    func test_indexKey_foldsCaseAndExtension() {
        XCTAssertEqual(WikiLink.indexKey(for: " Meeting Notes.md "), "meeting notes")
        XCTAssertEqual(WikiLink.indexKey(for: "meeting notes"), "meeting notes")
    }

    // MARK: - Autocomplete Token

    private func tokenAtEnd(of text: String) -> WikiLink.Token? {
        WikiLink.token(in: text as NSString, caret: (text as NSString).length)
    }

    func test_token_opensOnTheSecondBracket() {
        XCTAssertEqual(tokenAtEnd(of: "See [["),
                       WikiLink.Token(range: NSRange(location: 4, length: 2), query: ""))
    }

    func test_token_carriesWhatWasTypedAfterTheBrackets() {
        XCTAssertEqual(tokenAtEnd(of: "[[Meet")?.query, "Meet")
        XCTAssertEqual(tokenAtEnd(of: "[[Meet")?.range, NSRange(location: 0, length: 6))
    }

    func test_token_closedLinkIsNotAToken() {
        XCTAssertNil(tokenAtEnd(of: "[[Meeting Notes]]"))
    }

    func test_token_singleBracketIsNotAToken() {
        XCTAssertNil(tokenAtEnd(of: "[Meeting"))
    }

    func test_token_doesNotReachBackToAPreviousLine() {
        XCTAssertNil(tokenAtEnd(of: "[[Meeting\nNotes"))
    }

    func test_token_followsTheNearestOpenBrackets() {
        XCTAssertEqual(tokenAtEnd(of: "[[Done]] and [[Ne")?.query, "Ne")
        XCTAssertEqual(tokenAtEnd(of: "[[Done]] and [[Ne")?.range, NSRange(location: 13, length: 4))
    }

    func test_token_caretBeforeTheBrackets_isNotAToken() {
        XCTAssertNil(WikiLink.token(in: "[[Meeting" as NSString, caret: 1))
    }

    // MARK: - Relative Markdown Links

    private func relativeTitle(_ destination: String) -> String? {
        guard let url = URL(string: destination) else { return nil }
        return WikiLink.title(forRelativeLink: url)
    }

    func test_relativeLink_bareFileNameIsATitle() {
        XCTAssertEqual(relativeTitle("Help.md"), "Help.md")
        XCTAssertEqual(relativeTitle("Help"), "Help")
    }

    /// Drive resolves titles, not paths, so only the file name survives — which is what makes
    /// `[Help](./notes/Help.md)` and `[[Help]]` land on the same note.
    func test_relativeLink_keepsOnlyTheFileName() {
        XCTAssertEqual(relativeTitle("./Help.md"), "Help.md")
        XCTAssertEqual(relativeTitle("../notes/Help.md"), "Help.md")
        XCTAssertEqual(relativeTitle("/notes/Help.md"), "Help.md")
    }

    func test_relativeLink_decodesPercentEncoding() {
        XCTAssertEqual(relativeTitle("Meeting%20Notes.md"), "Meeting Notes.md")
    }

    /// The resolved title goes straight to `WikiLinkIndex`, which folds the extension and case
    /// away — the same fold that lets a link written on a phone find a note made on the web.
    func test_relativeLink_resolvesThroughTheSameIndexAsAWikiLink() {
        let note = NoteItem(id: "n1", name: "Help.md", type: .file, parentID: nil, size: 1,
                            modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
        let index = WikiLinkIndex(items: [note])

        XCTAssertEqual(index.item(for: relativeTitle("./docs/help.MD") ?? "")?.id, "n1")
    }

    func test_relativeLink_ignoresDestinationsWithAScheme() {
        XCTAssertNil(relativeTitle("https://example.com/Help.md"))
        XCTAssertNil(relativeTitle("mailto:someone@example.com"))
        XCTAssertNil(relativeTitle("nn-wikilink://Help"))
        XCTAssertNil(relativeTitle("nn-footnote://1"))
        XCTAssertNil(relativeTitle(NeutrinoAppLink.url(kind: .note, fileID: "n1")!.absoluteString))
    }

    func test_relativeLink_ignoresAnchorsAndPathsWithNoFileName() {
        XCTAssertNil(relativeTitle("#section"))
        XCTAssertNil(relativeTitle("/"))
        XCTAssertNil(relativeTitle("./"))
        XCTAssertNil(relativeTitle("../"))
    }
}
