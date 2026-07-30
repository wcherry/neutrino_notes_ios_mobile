import XCTest
@testable import NeutrinoNotes

/// Tests for `TagsService`'s cache behaviour — the parts that decide what the tag UI shows.
/// Tests use the DEBUG seed initializer to pre-populate state without network calls; the
/// optimistic mutations below fire a background request that fails without a token, which is
/// exactly what makes the rollback paths observable.
@MainActor
final class TagsServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTag(id: String, name: String) -> NoteTag {
        NoteTag(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Seeding / Queries

    func test_seededTags_areSortedByName() {
        let sut = TagsService(tags: [makeTag(id: "1", name: "zeta"), makeTag(id: "2", name: "Alpha")])

        XCTAssertEqual(sut.tags.map(\.name), ["Alpha", "zeta"])
    }

    func test_tagsForFile_returnsCachedTags() {
        let work = makeTag(id: "t1", name: "Work")
        let sut = TagsService(tags: [work], tagsByFileID: ["file-1": [work]])

        XCTAssertEqual(sut.tags(for: "file-1").map(\.id), ["t1"])
    }

    func test_tagsForFile_unknownFile_isEmptyRatherThanNil() {
        let sut = TagsService(tags: [makeTag(id: "t1", name: "Work")])

        XCTAssertEqual(sut.tags(for: "never-loaded"), [])
    }

    // MARK: - Rename

    func test_renameTag_updatesTheTagListImmediately() {
        let tag = makeTag(id: "t1", name: "Work")
        let sut = TagsService(tags: [tag])

        sut.renameTag(tag, to: "Projects")

        XCTAssertEqual(sut.tags.first?.name, "Projects")
    }

    func test_renameTag_updatesEveryPerFileCacheThatCarriesIt() {
        let tag = makeTag(id: "t1", name: "Work")
        let other = makeTag(id: "t2", name: "Personal")
        let sut = TagsService(tags: [tag, other],
                              tagsByFileID: ["file-1": [tag], "file-2": [other, tag]])

        sut.renameTag(tag, to: "Projects")

        XCTAssertEqual(sut.tags(for: "file-1").map(\.name), ["Projects"])
        XCTAssertEqual(Set(sut.tags(for: "file-2").map(\.name)), ["Personal", "Projects"])
    }

    func test_renameTag_reSortsTheList() {
        let tag = makeTag(id: "t1", name: "Alpha")
        let sut = TagsService(tags: [tag, makeTag(id: "t2", name: "Beta")])

        sut.renameTag(tag, to: "Zeta")

        XCTAssertEqual(sut.tags.map(\.name), ["Beta", "Zeta"])
    }

    func test_renameTag_toTheSameName_isANoOp() {
        let tag = makeTag(id: "t1", name: "Work")
        let sut = TagsService(tags: [tag])

        sut.renameTag(tag, to: "  Work  ")

        XCTAssertEqual(sut.tags.map(\.name), ["Work"])
    }

    func test_renameTag_toAnEmptyName_isRejected() {
        let tag = makeTag(id: "t1", name: "Work")
        let sut = TagsService(tags: [tag])

        sut.renameTag(tag, to: "   ")

        XCTAssertEqual(sut.tags.map(\.name), ["Work"])
    }

    // MARK: - Delete

    func test_deleteTag_removesItFromTheListImmediately() {
        let tag = makeTag(id: "t1", name: "Work")
        let sut = TagsService(tags: [tag, makeTag(id: "t2", name: "Personal")])

        sut.deleteTag(tag)

        XCTAssertEqual(sut.tags.map(\.id), ["t2"])
    }

    /// The server detaches a deleted tag from every file, so the per-file caches must follow.
    func test_deleteTag_detachesItFromEveryCachedFile() {
        let tag = makeTag(id: "t1", name: "Work")
        let other = makeTag(id: "t2", name: "Personal")
        let sut = TagsService(tags: [tag, other],
                              tagsByFileID: ["file-1": [tag], "file-2": [tag, other]])

        sut.deleteTag(tag)

        XCTAssertEqual(sut.tags(for: "file-1"), [])
        XCTAssertEqual(sut.tags(for: "file-2").map(\.id), ["t2"])
    }

    // MARK: - Errors

    func test_duplicateNameError_namesTheTag() {
        let message = TagsError.duplicateName("Work").errorDescription

        XCTAssertEqual(message, "A tag named \u{201C}Work\u{201D} already exists.")
    }

    func test_serverErrorDescription_includesTheStatusCode() {
        XCTAssertEqual(TagsError.serverError(statusCode: 409).errorDescription, "Server error (409).")
    }
}
