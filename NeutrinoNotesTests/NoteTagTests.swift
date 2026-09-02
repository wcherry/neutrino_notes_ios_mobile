import XCTest
import NeutrinoCore
@testable import NeutrinoNotes

/// Tests for the `NoteTag` model: decoding the shapes Drive's tag endpoints actually emit, and
/// the ordering the tag list relies on.
final class NoteTagTests: XCTestCase {

    // MARK: - Decoding

    func test_decode_readsCamelCaseAndZonelessTimestamps() throws {
        // Tag payloads carry Rust's NaiveDateTime — no zone, microsecond precision — like the
        // file and folder endpoints.
        let json = #"{"id":"tag-1","name":"Work","createdAt":"2026-07-30T14:25:36.123456"}"#

        let tag = try NoteTag.decoder.decode(NoteTag.self, from: Data(json.utf8))

        XCTAssertEqual(tag.id, "tag-1")
        XCTAssertEqual(tag.name, "Work")
        XCTAssertEqual(tag.createdAt, DriveDate.date(from: "2026-07-30T14:25:36.123456"))
    }

    func test_decode_readsZonedTimestamps() throws {
        let json = #"{"id":"tag-2","name":"Personal","createdAt":"2026-07-30T14:25:36Z"}"#

        let tag = try NoteTag.decoder.decode(NoteTag.self, from: Data(json.utf8))

        XCTAssertEqual(tag.createdAt, DriveDate.date(from: "2026-07-30T14:25:36Z"))
    }

    func test_decode_listOfTags() throws {
        let json = """
        [{"id":"a","name":"Alpha","createdAt":"2026-07-30T14:25:36"},
         {"id":"b","name":"Beta","createdAt":"2026-07-30T14:25:37"}]
        """

        let tags = try NoteTag.decoder.decode([NoteTag].self, from: Data(json.utf8))

        XCTAssertEqual(tags.map(\.name), ["Alpha", "Beta"])
    }

    // MARK: - File Count

    func test_decode_readsTheServersFileCount() throws {
        let json = #"{"id":"tag-1","name":"Work","createdAt":"2026-07-30T14:25:36","fileCount":7}"#

        let tag = try NoteTag.decoder.decode(NoteTag.self, from: Data(json.utf8))

        XCTAssertEqual(tag.fileCount, 7)
    }

    /// Drive added `fileCount` after this app first shipped tags, so a server without it must
    /// still yield a usable tag rather than failing the whole list.
    func test_decode_withoutFileCount_defaultsToZero() throws {
        let json = #"{"id":"tag-1","name":"Work","createdAt":"2026-07-30T14:25:36"}"#

        let tag = try NoteTag.decoder.decode(NoteTag.self, from: Data(json.utf8))

        XCTAssertEqual(tag.fileCount, 0)
    }

    func test_decode_unparseableDate_throws() {
        let json = #"{"id":"tag-3","name":"Broken","createdAt":"yesterday"}"#

        XCTAssertThrowsError(try NoteTag.decoder.decode(NoteTag.self, from: Data(json.utf8)))
    }

    // MARK: - Ordering

    func test_byName_isCaseInsensitive() {
        let lower = NoteTag(id: "1", name: "alpha", createdAt: Date())
        let upper = NoteTag(id: "2", name: "Beta", createdAt: Date())

        XCTAssertTrue(NoteTag.byName(lower, upper))
        XCTAssertFalse(NoteTag.byName(upper, lower))
    }

    func test_byName_breaksTiesOnIDSoTheOrderIsTotal() {
        let first = NoteTag(id: "1", name: "Work", createdAt: Date())
        let second = NoteTag(id: "2", name: "work", createdAt: Date())

        XCTAssertTrue(NoteTag.byName(first, second))
        XCTAssertFalse(NoteTag.byName(second, first))
    }

    func test_sortedByName_ordersMixedCaseNaturally() {
        let tags = [
            NoteTag(id: "1", name: "zeta", createdAt: Date()),
            NoteTag(id: "2", name: "Alpha", createdAt: Date()),
            NoteTag(id: "3", name: "beta", createdAt: Date())
        ]

        XCTAssertEqual(tags.sorted(by: NoteTag.byName).map(\.name), ["Alpha", "beta", "zeta"])
    }
}
