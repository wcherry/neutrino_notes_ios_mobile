import XCTest
@testable import NeutrinoNotes

/// Tests for `WikiLinkIndex` — the device-side half of link resolution, which decides which links
/// look live and what the `[[` menu offers.
final class WikiLinkIndexTests: XCTestCase {

    // MARK: - Fixtures

    private func note(_ id: String, _ name: String,
                      modifiedAt: Date = Date(timeIntervalSince1970: 1_000),
                      isTrashed: Bool = false) -> NoteItem {
        NoteItem(id: id, name: name, type: .file, parentID: nil, size: 10,
                 modifiedAt: modifiedAt, isTrashed: isTrashed, mimeType: NoteItem.markdownMIME)
    }

    private func folder(_ id: String, _ name: String) -> NoteItem {
        NoteItem(id: id, name: name, type: .folder, parentID: nil, size: nil,
                 modifiedAt: Date(timeIntervalSince1970: 1_000), isTrashed: false, mimeType: nil)
    }

    // MARK: - Resolution

    func test_item_resolvesATitleWithoutTheExtensionTheAppAppends() {
        let index = WikiLinkIndex(items: [note("1", "Meeting Notes.md")])
        XCTAssertEqual(index.item(for: "Meeting Notes")?.id, "1")
    }

    func test_item_resolvesTheFullNameToo() {
        let index = WikiLinkIndex(items: [note("1", "Meeting Notes.md")])
        XCTAssertEqual(index.item(for: "Meeting Notes.md")?.id, "1")
    }

    func test_item_resolvesANoteCreatedByTheWebAppWithNoExtension() {
        let index = WikiLinkIndex(items: [note("1", "Untitled note")])
        XCTAssertEqual(index.item(for: "untitled NOTE")?.id, "1")
    }

    func test_item_isNilForATitleNothingMatches() {
        XCTAssertNil(WikiLinkIndex(items: [note("1", "A.md")]).item(for: "B"))
    }

    func test_item_ignoresFoldersAndTrashedNotes() {
        let index = WikiLinkIndex(items: [
            folder("f", "Meeting Notes"),
            note("t", "Archive.md", isTrashed: true),
        ])
        XCTAssertNil(index.item(for: "Meeting Notes"))
        XCTAssertNil(index.item(for: "Archive"))
        XCTAssertTrue(index.isEmpty)
    }

    func test_item_duplicateTitles_resolveToTheMostRecentlyEdited() {
        // Two notes can legitimately share a title. Picking the newest at least makes the choice
        // predictable to whoever typed the link.
        let older = note("old", "Notes.md", modifiedAt: Date(timeIntervalSince1970: 1_000))
        let newer = note("new", "Notes.md", modifiedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(WikiLinkIndex(items: [older, newer]).item(for: "Notes")?.id, "new")
        XCTAssertEqual(WikiLinkIndex(items: [newer, older]).item(for: "Notes")?.id, "new")
    }

    // MARK: - Suggestions

    func test_suggestions_prefixMatchesComeBeforeSubstringMatches() {
        let index = WikiLinkIndex(items: [
            note("1", "Weekly Meeting.md"),
            note("2", "Meeting Notes.md"),
        ])
        XCTAssertEqual(index.suggestions(for: "meet").map(\.id), ["2", "1"])
    }

    func test_suggestions_emptyQueryOffersTheMostRecentlyEditedFirst() {
        let index = WikiLinkIndex(items: [
            note("old", "A.md", modifiedAt: Date(timeIntervalSince1970: 1_000)),
            note("new", "B.md", modifiedAt: Date(timeIntervalSince1970: 2_000)),
        ])
        XCTAssertEqual(index.suggestions(for: "").map(\.id), ["new", "old"])
    }

    func test_suggestions_respectTheLimit() {
        let index = WikiLinkIndex(items: (1...20).map { note("\($0)", "Note \($0).md") })
        XCTAssertEqual(index.suggestions(for: "note", limit: 3).count, 3)
    }

    func test_suggestions_areEmptyWhenNothingMatches() {
        XCTAssertTrue(WikiLinkIndex(items: [note("1", "A.md")]).suggestions(for: "zzz").isEmpty)
    }
}
