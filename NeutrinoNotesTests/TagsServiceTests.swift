import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoNotes

/// Tests for `TagsService`'s cache behaviour — the parts that decide what the tag UI shows.
/// Tests use the DEBUG seed initializer to pre-populate state without network calls; the
/// optimistic mutations below fire a background request that fails without a token, which is
/// exactly what makes the rollback paths observable.
@MainActor
final class TagsServiceTests: XCTestCase {

    // MARK: - Lifecycle

    /// Guarantees the "no token" precondition these tests lean on: without one, every request
    /// fails in `authorized` before anything reaches the network.
    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

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

    // MARK: - Applying a Selection

    func test_tagDiff_reportsBothDirections() {
        let diff = TagsService.tagDiff(current: ["a", "b"], selected: ["b", "c"])

        XCTAssertEqual(diff.added, ["c"])
        XCTAssertEqual(diff.removed, ["a"])
    }

    func test_tagDiff_unchangedSelection_isNoWork() {
        let diff = TagsService.tagDiff(current: ["a", "b"], selected: ["b", "a"])

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func test_tagDiff_clearingEverything_removesEveryCurrentTag() {
        let diff = TagsService.tagDiff(current: ["a", "b"], selected: [])

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed, ["a", "b"])
    }

    func test_tagDiff_firstTagOnAnUntaggedNote_isAnAdd() {
        let diff = TagsService.tagDiff(current: [], selected: ["a"])

        XCTAssertEqual(diff.added, ["a"])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    /// Writes are per-tag and the cache follows the server, so a rejected write must leave the
    /// cache showing what the note still actually carries.
    func test_applyTags_whenTheWriteFails_leavesTheCacheAlone() async {
        let work = makeTag(id: "t1", name: "Work")
        let personal = makeTag(id: "t2", name: "Personal")
        let sut = TagsService(tags: [work, personal], tagsByFileID: ["file-1": [work]])

        // No access token in the keychain, so every request fails before it is sent.
        do {
            try await sut.applyTags(["t2"], to: "file-1")
            XCTFail("Expected the unauthenticated write to throw")
        } catch {
            XCTAssertEqual(sut.tags(for: "file-1").map(\.id), ["t1"])
        }
    }

    // MARK: - Tagged Files

    func test_taggedFileResponse_decodesTheFullFileShape() throws {
        let json = """
        {"files":[{"id":"f1","name":"Meeting Notes.md","mimeType":"application/x-neutrino-note",
                   "sizeBytes":512,"folderId":"dir-1","isStarred":true,
                   "createdAt":"2026-07-30T14:25:36","updatedAt":"2026-07-30T15:00:00",
                   "contentVersion":3}],
         "total":1,"limit":200,"offset":0}
        """

        let response = try NoteTag.decoder.decode(APIListTaggedFilesResponse.self, from: Data(json.utf8))
        let note = NoteItem(taggedFile: try XCTUnwrap(response.files.first))

        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(note.id, "f1")
        XCTAssertEqual(note.parentID, "dir-1")
        XCTAssertEqual(note.size, 512)
        XCTAssertEqual(note.mimeType, NoteItem.markdownMIME)
        // The star flag is what makes a note reached through a tag render like it does in the
        // browser; the endpoint used to omit it.
        XCTAssertTrue(note.isStarred)
        XCTAssertFalse(note.isTrashed)
    }

    /// A server predating the full file shape still lists a tag's notes, just without stars.
    func test_taggedFileResponse_withoutTheStarFlag_decodesAsUnstarred() throws {
        let json = """
        {"files":[{"id":"f1","name":"Old.md","mimeType":"application/x-neutrino-note",
                   "sizeBytes":10,"folderId":null,"updatedAt":"2026-07-30T15:00:00"}],
         "total":1}
        """

        let response = try NoteTag.decoder.decode(APIListTaggedFilesResponse.self, from: Data(json.utf8))
        let note = NoteItem(taggedFile: try XCTUnwrap(response.files.first))

        XCTAssertFalse(note.isStarred)
        XCTAssertNil(note.parentID)
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
