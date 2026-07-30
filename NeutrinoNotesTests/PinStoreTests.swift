import XCTest
@testable import NeutrinoNotes

/// Tests for `PinStore`, the device-local pin list backing Epic 12. Every test gets its own
/// `UserDefaults` suite so nothing touches the app's real preferences.
@MainActor
final class PinStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        suiteName = "PinStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        super.tearDown()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - Helpers

    private func makeStore() -> PinStore {
        PinStore(defaults: defaults)
    }

    private func makeItem(id: String, name: String = "Note.md") -> NoteItem {
        NoteItem(id: id, name: name, type: .file, parentID: nil, size: 128,
                 modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    // MARK: - Pin / Unpin

    func test_newStore_hasNoPins() {
        let sut = makeStore()

        XCTAssertEqual(sut.pinnedIDs, [])
        XCTAssertEqual(sut.pinnedCount, 0)
        XCTAssertFalse(sut.isPinned("anything"))
    }

    func test_pin_marksItemPinned() {
        let sut = makeStore()

        sut.pin("note-1")

        XCTAssertTrue(sut.isPinned("note-1"))
        XCTAssertEqual(sut.pinnedCount, 1)
    }

    func test_pin_twice_doesNotDuplicate() {
        let sut = makeStore()

        sut.pin("note-1")
        sut.pin("note-1")

        XCTAssertEqual(sut.pinnedIDs, ["note-1"])
    }

    func test_pin_putsMostRecentFirst() {
        let sut = makeStore()

        sut.pin("first")
        sut.pin("second")

        XCTAssertEqual(sut.pinnedIDs, ["second", "first"])
    }

    func test_unpin_removesItem() {
        let sut = makeStore()
        sut.pin("note-1")

        sut.unpin("note-1")

        XCTAssertFalse(sut.isPinned("note-1"))
        XCTAssertEqual(sut.pinnedIDs, [])
    }

    func test_unpin_unknownID_isANoOp() {
        let sut = makeStore()
        sut.pin("note-1")

        sut.unpin("never-pinned")

        XCTAssertEqual(sut.pinnedIDs, ["note-1"])
    }

    func test_togglePin_flipsBothWays() {
        let sut = makeStore()

        sut.togglePin("note-1")
        XCTAssertTrue(sut.isPinned("note-1"))

        sut.togglePin("note-1")
        XCTAssertFalse(sut.isPinned("note-1"))
    }

    func test_unpinAll_clearsEverything() {
        let sut = makeStore()
        sut.pin("a")
        sut.pin("b")

        sut.unpinAll()

        XCTAssertEqual(sut.pinnedIDs, [])
    }

    // MARK: - Persistence

    func test_pins_surviveANewStoreOverTheSameDefaults() {
        let first = makeStore()
        first.pin("note-1")
        first.pin("note-2")

        let second = makeStore()

        XCTAssertEqual(second.pinnedIDs, ["note-2", "note-1"])
    }

    func test_pinsArePersistedUnderTheDocumentedKey() {
        let sut = makeStore()

        sut.pin("note-1")

        XCTAssertEqual(defaults.stringArray(forKey: PinStore.defaultsKey), ["note-1"])
    }

    // MARK: - Ordering

    func test_sorted_floatsPinnedItemsToTheTop() {
        let sut = makeStore()
        sut.pin("c")
        let items = [makeItem(id: "a"), makeItem(id: "b"), makeItem(id: "c")]

        let ordered = sut.sorted(items)

        XCTAssertEqual(ordered.map(\.id), ["c", "a", "b"])
    }

    func test_sorted_ordersPinnedItemsByMostRecentlyPinned() {
        let sut = makeStore()
        sut.pin("a")
        sut.pin("c")
        let items = [makeItem(id: "a"), makeItem(id: "b"), makeItem(id: "c")]

        let ordered = sut.sorted(items)

        XCTAssertEqual(ordered.map(\.id), ["c", "a", "b"])
    }

    func test_sorted_leavesUnpinnedItemsInTheirGivenOrder() {
        let sut = makeStore()
        sut.pin("b")
        let items = [makeItem(id: "z"), makeItem(id: "b"), makeItem(id: "a")]

        let ordered = sut.sorted(items)

        XCTAssertEqual(ordered.map(\.id), ["b", "z", "a"])
    }

    func test_sorted_withNoPins_returnsTheListUnchanged() {
        let sut = makeStore()
        let items = [makeItem(id: "a"), makeItem(id: "b")]

        XCTAssertEqual(sut.sorted(items).map(\.id), ["a", "b"])
    }

    /// A pin for a note that has since been deleted must not disturb the listing it appears in.
    func test_sorted_ignoresPinsForItemsNotInTheList() {
        let sut = makeStore()
        sut.pin("deleted-note")
        let items = [makeItem(id: "a"), makeItem(id: "b")]

        XCTAssertEqual(sut.sorted(items).map(\.id), ["a", "b"])
    }
}
