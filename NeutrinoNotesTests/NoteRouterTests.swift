import XCTest
@testable import NeutrinoNotes

/// Tests for `NoteRouter` — the hand-off that lets a pushed editor open another note on the stack
/// that pushed it.
@MainActor
final class NoteRouterTests: XCTestCase {

    private func note(_ id: String) -> NoteItem {
        NoteItem(id: id, name: "\(id).md", type: .file, parentID: nil, size: 1,
                 modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    func test_open_holdsTheNoteUntilItIsConsumed() {
        let router = NoteRouter()
        XCTAssertNil(router.pending)

        router.open(note("a"))
        XCTAssertEqual(router.pending?.id, "a")
        XCTAssertEqual(router.consume()?.id, "a")
    }

    func test_consume_clearsTheNoteSoARerenderCannotPushItTwice() {
        let router = NoteRouter()
        router.open(note("a"))
        _ = router.consume()
        XCTAssertNil(router.pending)
        XCTAssertNil(router.consume())
    }

    func test_open_replacesAnUnconsumedNote() {
        let router = NoteRouter()
        router.open(note("a"))
        router.open(note("b"))
        XCTAssertEqual(router.consume()?.id, "b")
    }

    func test_routersAreIndependent_soATapInOneTabDoesNotPushInAnother() {
        let notes = NoteRouter()
        let recents = NoteRouter()
        notes.open(note("a"))
        XCTAssertNil(recents.pending)
    }
}
