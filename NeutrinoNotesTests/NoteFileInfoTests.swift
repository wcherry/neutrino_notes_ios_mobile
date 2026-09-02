import XCTest
import NeutrinoCore
@testable import NeutrinoNotes

/// Tests for `GET /drive/files/{id}/info` decoding — the endpoint that tells the editor what this
/// account may do with a shared note, and tells `SyncEngine` what version the server is on.
final class NoteFileInfoTests: XCTestCase {

    // MARK: - Fixtures

    private func json(deletedAt: String = "null", role: String = "editor") -> Data {
        Data("""
        {"id":"f1","name":"Meeting Notes.md","sizeBytes":512,"folderId":"dir-1",
         "deletedAt":\(deletedAt),"yourRole":"\(role)","storagePath":"/x",
         "mimeType":"application/x-neutrino-note","createdAt":"2026-07-30T14:25:36",
         "updatedAt":"2026-07-30T15:00:00","tags":[]}
        """.utf8)
    }

    // MARK: - Decoding

    func test_decodesTheFileInfoPayload() throws {
        let info = try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: json())

        XCTAssertEqual(info.id, "f1")
        XCTAssertEqual(info.name, "Meeting Notes.md")
        XCTAssertEqual(info.sizeBytes, 512)
        XCTAssertEqual(info.folderID, "dir-1")
        XCTAssertEqual(info.mimeType, NoteItem.markdownMIME)
        XCTAssertEqual(info.yourRole, .editor)
        XCTAssertNil(info.deletedAt)
        XCTAssertTrue(info.isLive)
    }

    /// Drive's zone-less `NaiveDateTime`, which `DriveDate` reads as UTC.
    func test_decodesDriveTimestamps() throws {
        let info = try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: json())

        let expected = DriveDate.date(from: "2026-07-30T15:00:00")
        XCTAssertEqual(info.updatedAt, expected)
    }

    /// `/info` still describes a trashed file, unlike the listings, so "is it still there" has to
    /// be read off `deletedAt` — which is what stops the sync engine uploading into the Trash.
    func test_trashedFile_isNotLive() throws {
        let info = try NoteFileInfo.decoder.decode(
            NoteFileInfo.self, from: json(deletedAt: "\"2026-07-30T16:00:00\"")
        )

        XCTAssertNotNil(info.deletedAt)
        XCTAssertFalse(info.isLive)
    }

    func test_viewerRole_isDecodedAsReadOnly() throws {
        let info = try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: json(role: "viewer"))

        XCTAssertEqual(info.yourRole, .viewer)
        XCTAssertFalse(info.yourRole.canEdit)
    }

    /// An older server, or a role this app has never heard of, must still produce a usable answer.
    func test_unknownRole_decodesAsViewer() throws {
        let info = try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: json(role: "organizer"))

        XCTAssertEqual(info.yourRole, .viewer)
    }

    func test_missingOptionalFields_stillDecode() throws {
        let json = Data("""
        {"id":"f1","name":"Note.md","yourRole":"owner","updatedAt":"2026-07-30T15:00:00"}
        """.utf8)

        let info = try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: json)

        XCTAssertEqual(info.sizeBytes, 0)
        XCTAssertNil(info.folderID)
        XCTAssertNil(info.mimeType)
        XCTAssertTrue(info.isLive)
    }
}
