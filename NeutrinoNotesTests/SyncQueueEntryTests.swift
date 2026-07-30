import XCTest
@testable import NeutrinoNotes

/// Unit tests for `SyncQueueEntry` — pure logic, no I/O. Covers the static factories that
/// `NotesDriveService`/`NoteContentService` will call from their catch blocks (correct `kind`
/// and correct field population, with every unrelated field left `nil`), the exponential
/// backoff formula, `maxAttempts`, and the `Codable` round trip that is the actual on-disk
/// persistence format `SyncPersistence` writes to `queue.json`.
@MainActor
final class SyncQueueEntryTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFolder(id: String, name: String, parentID: String? = nil) -> NoteItem {
        NoteItem(id: id, name: name, type: .folder, parentID: parentID,
                 size: nil, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                 isTrashed: false, mimeType: nil)
    }

    private func makeFile(id: String, name: String, parentID: String? = nil) -> NoteItem {
        NoteItem(id: id, name: name, type: .file, parentID: parentID,
                 size: 1024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                 isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    // MARK: - createFolder

    func test_createFolder_populatesKindAndRelevantFields() {
        let entry = SyncQueueEntry.createFolder(placeholderID: "placeholder-1", name: "New Folder", parentID: "parent-1")

        XCTAssertEqual(entry.kind, .createFolder)
        XCTAssertEqual(entry.placeholderID, "placeholder-1")
        XCTAssertEqual(entry.newName, "New Folder")
        XCTAssertEqual(entry.newParentID, "parent-1")
    }

    func test_createFolder_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.createFolder(placeholderID: "placeholder-1", name: "New Folder", parentID: nil)

        XCTAssertNil(entry.itemID)
        XCTAssertNil(entry.previousName)
        XCTAssertNil(entry.previousParentID)
        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.encryptedContentBase64)
        XCTAssertNil(entry.fileName)
        XCTAssertNil(entry.mimeType)
        XCTAssertNil(entry.baseModifiedAt)
        XCTAssertNil(entry.lastError)
    }

    // MARK: - renameFolder / renameFile

    func test_renameFolder_populatesKindAndRelevantFields() {
        let entry = SyncQueueEntry.renameFolder(itemID: "folder-1", newName: "New", previousName: "Old")

        XCTAssertEqual(entry.kind, .renameFolder)
        XCTAssertEqual(entry.itemID, "folder-1")
        XCTAssertEqual(entry.newName, "New")
        XCTAssertEqual(entry.previousName, "Old")
    }

    func test_renameFolder_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.renameFolder(itemID: "folder-1", newName: "New", previousName: "Old")

        XCTAssertNil(entry.placeholderID)
        XCTAssertNil(entry.newParentID)
        XCTAssertNil(entry.previousParentID)
        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.encryptedContentBase64)
        XCTAssertNil(entry.fileName)
        XCTAssertNil(entry.mimeType)
        XCTAssertNil(entry.baseModifiedAt)
    }

    func test_renameFile_populatesKindAndRelevantFields() {
        let entry = SyncQueueEntry.renameFile(itemID: "file-1", newName: "New.md", previousName: "Old.md")

        XCTAssertEqual(entry.kind, .renameFile)
        XCTAssertEqual(entry.itemID, "file-1")
        XCTAssertEqual(entry.newName, "New.md")
        XCTAssertEqual(entry.previousName, "Old.md")
    }

    func test_renameFile_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.renameFile(itemID: "file-1", newName: "New.md", previousName: "Old.md")

        XCTAssertNil(entry.placeholderID)
        XCTAssertNil(entry.newParentID)
        XCTAssertNil(entry.previousParentID)
        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.trashSnapshot)
    }

    // MARK: - trashFile / trashFolder

    func test_trashFile_populatesKindItemIDAndSnapshot() {
        let file = makeFile(id: "f1", name: "Doc.md")
        let entry = SyncQueueEntry.trashFile(itemID: "f1", snapshot: file)

        XCTAssertEqual(entry.kind, .trashFile)
        XCTAssertEqual(entry.itemID, "f1")
        XCTAssertEqual(entry.itemSnapshot, file)
    }

    func test_trashFile_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.trashFile(itemID: "f1", snapshot: makeFile(id: "f1", name: "Doc.md"))

        XCTAssertNil(entry.newName)
        XCTAssertNil(entry.previousName)
        XCTAssertNil(entry.newParentID)
        XCTAssertNil(entry.previousParentID)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.placeholderID)
    }

    func test_trashFolder_populatesKindItemIDAndSnapshot() {
        let folder = makeFolder(id: "d1", name: "Folder")
        let entry = SyncQueueEntry.trashFolder(itemID: "d1", snapshot: folder)

        XCTAssertEqual(entry.kind, .trashFolder)
        XCTAssertEqual(entry.itemID, "d1")
        XCTAssertEqual(entry.itemSnapshot, folder)
    }

    // MARK: - permanentDeleteFile / permanentDeleteFolder

    func test_permanentDeleteFile_populatesKindItemIDAndSnapshot() {
        let file = makeFile(id: "f1", name: "Doc.md")
        let entry = SyncQueueEntry.permanentDeleteFile(itemID: "f1", snapshot: file)

        XCTAssertEqual(entry.kind, .permanentDeleteFile)
        XCTAssertEqual(entry.itemID, "f1")
        XCTAssertEqual(entry.itemSnapshot, file)
    }

    func test_permanentDeleteFile_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.permanentDeleteFile(itemID: "f1", snapshot: makeFile(id: "f1", name: "Doc.md"))

        XCTAssertNil(entry.newName)
        XCTAssertNil(entry.newParentID)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.encryptedContentBase64)
    }

    func test_permanentDeleteFolder_populatesKindItemIDAndSnapshot() {
        let folder = makeFolder(id: "d1", name: "Folder")
        let entry = SyncQueueEntry.permanentDeleteFolder(itemID: "d1", snapshot: folder)

        XCTAssertEqual(entry.kind, .permanentDeleteFolder)
        XCTAssertEqual(entry.itemID, "d1")
        XCTAssertEqual(entry.itemSnapshot, folder)
    }

    // MARK: - moveFile / moveFolder

    func test_moveFile_populatesKindAndParentFields() {
        let entry = SyncQueueEntry.moveFile(itemID: "f1", newParentID: "folder-b", previousParentID: "folder-a")

        XCTAssertEqual(entry.kind, .moveFile)
        XCTAssertEqual(entry.itemID, "f1")
        XCTAssertEqual(entry.newParentID, "folder-b")
        XCTAssertEqual(entry.previousParentID, "folder-a")
    }

    func test_moveFile_toRoot_setsNewParentIDNil() {
        let entry = SyncQueueEntry.moveFile(itemID: "f1", newParentID: nil, previousParentID: "folder-a")

        XCTAssertEqual(entry.kind, .moveFile)
        XCTAssertNil(entry.newParentID)
        XCTAssertEqual(entry.previousParentID, "folder-a")
    }

    func test_moveFile_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.moveFile(itemID: "f1", newParentID: "folder-b", previousParentID: "folder-a")

        XCTAssertNil(entry.newName)
        XCTAssertNil(entry.previousName)
        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.placeholderID)
    }

    func test_moveFolder_populatesKindAndParentFields() {
        let entry = SyncQueueEntry.moveFolder(itemID: "d1", newParentID: "folder-b", previousParentID: "folder-a")

        XCTAssertEqual(entry.kind, .moveFolder)
        XCTAssertEqual(entry.itemID, "d1")
        XCTAssertEqual(entry.newParentID, "folder-b")
        XCTAssertEqual(entry.previousParentID, "folder-a")
    }

    // MARK: - restoreFile / restoreFolder

    func test_restoreFile_populatesKindItemIDAndSnapshot() {
        var trashed = makeFile(id: "f1", name: "Doc.md")
        trashed.isTrashed = true
        let entry = SyncQueueEntry.restoreFile(itemID: "f1", snapshot: trashed)

        XCTAssertEqual(entry.kind, .restoreFile)
        XCTAssertEqual(entry.itemID, "f1")
        XCTAssertEqual(entry.itemSnapshot, trashed)
    }

    func test_restoreFolder_populatesKindItemIDAndSnapshot() {
        var trashed = makeFolder(id: "d1", name: "Folder")
        trashed.isTrashed = true
        let entry = SyncQueueEntry.restoreFolder(itemID: "d1", snapshot: trashed)

        XCTAssertEqual(entry.kind, .restoreFolder)
        XCTAssertEqual(entry.itemID, "d1")
        XCTAssertEqual(entry.itemSnapshot, trashed)
    }

    // MARK: - emptyTrash

    func test_emptyTrash_populatesKindAndTrashSnapshot() {
        let snapshot = [makeFile(id: "f1", name: "A"), makeFolder(id: "d1", name: "B")]
        let entry = SyncQueueEntry.emptyTrash(snapshot: snapshot)

        XCTAssertEqual(entry.kind, .emptyTrash)
        XCTAssertEqual(entry.trashSnapshot, snapshot)
    }

    func test_emptyTrash_itemIDIsNil() {
        // Per SyncQueueEntry's field documentation: itemID is nil only for emptyTrash.
        let entry = SyncQueueEntry.emptyTrash(snapshot: [])

        XCTAssertNil(entry.itemID)
    }

    func test_emptyTrash_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.emptyTrash(snapshot: [makeFile(id: "f1", name: "A")])

        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.newName)
        XCTAssertNil(entry.placeholderID)
        XCTAssertNil(entry.encryptedContentBase64)
    }

    // MARK: - saveNoteContent

    func test_saveNoteContent_populatesKindAndAllContentFields() {
        let baseModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: baseModifiedAt
        )

        XCTAssertEqual(entry.kind, .saveNoteContent)
        XCTAssertEqual(entry.itemID, "f1")
        XCTAssertEqual(entry.encryptedContentBase64, "cGxhaW50ZXh0")
        XCTAssertEqual(entry.fileName, "Note.md")
        XCTAssertEqual(entry.mimeType, NoteItem.markdownMIME)
        XCTAssertEqual(entry.baseModifiedAt, baseModifiedAt)
    }

    func test_saveNoteContent_baseModifiedAtNil_isAllowed() {
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: nil
        )

        XCTAssertNil(entry.baseModifiedAt)
    }

    func test_saveNoteContent_leavesUnrelatedFieldsNil() {
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: nil
        )

        XCTAssertNil(entry.newName)
        XCTAssertNil(entry.previousName)
        XCTAssertNil(entry.newParentID)
        XCTAssertNil(entry.previousParentID)
        XCTAssertNil(entry.itemSnapshot)
        XCTAssertNil(entry.trashSnapshot)
        XCTAssertNil(entry.placeholderID)
    }

    // MARK: - Defaults

    func test_init_defaultAttemptCount_isZero() {
        let entry = SyncQueueEntry.renameFile(itemID: "f1", newName: "New", previousName: "Old")
        XCTAssertEqual(entry.attemptCount, 0)
    }

    func test_init_defaultLastError_isNil() {
        let entry = SyncQueueEntry.renameFile(itemID: "f1", newName: "New", previousName: "Old")
        XCTAssertNil(entry.lastError)
    }

    // MARK: - maxAttempts

    func test_maxAttempts_equals8() {
        XCTAssertEqual(SyncQueueEntry.maxAttempts, 8)
    }

    // MARK: - backoffInterval(forAttempt:)

    func test_backoffInterval_attempt0_returns5Seconds() {
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 0), 5, accuracy: 0.001)
    }

    func test_backoffInterval_attempt1_returns10Seconds() {
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 1), 10, accuracy: 0.001)
    }

    func test_backoffInterval_attempt2_returns20Seconds() {
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 2), 20, accuracy: 0.001)
    }

    func test_backoffInterval_attempt3_returns40Seconds() {
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 3), 40, accuracy: 0.001)
    }

    func test_backoffInterval_attempt7_growsExponentiallyJustBelowCap() {
        // 2^7 * 5s = 640s, still under the 900s (15 min) cap.
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 7), 640, accuracy: 0.001)
    }

    func test_backoffInterval_attempt8_isClampedAt15MinuteCap() {
        // 2^8 * 5s = 1280s, which must be clamped down to the 900s cap.
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 8), 900, accuracy: 0.001)
    }

    func test_backoffInterval_attempt10_remainsClampedAt15MinuteCap() {
        // Far past the point the raw exponential would exceed the cap — confirms the cap is a
        // hard clamp, not just a coincidental match at the boundary.
        XCTAssertEqual(SyncQueueEntry.backoffInterval(forAttempt: 10), 900, accuracy: 0.001)
    }

    // MARK: - Codable round trip

    func test_codableRoundTrip_fullyPopulatedEntry_preservesAllFieldsExactly() throws {
        let folderSnapshot = makeFolder(id: "folder-1", name: "Snapshot Folder")
        let trashSnapshot = [makeFile(id: "f1", name: "One"), makeFolder(id: "d1", name: "Two")]

        let entry = SyncQueueEntry(
            id: UUID(),
            kind: .saveNoteContent,
            itemID: "item-1",
            placeholderID: "placeholder-1",
            newName: "New Name",
            previousName: "Old Name",
            newParentID: "parent-new",
            previousParentID: "parent-old",
            itemSnapshot: folderSnapshot,
            trashSnapshot: trashSnapshot,
            encryptedContentBase64: "cGxhaW50ZXh0",
            fileName: "Note.md",
            mimeType: NoteItem.markdownMIME,
            baseModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            attemptCount: 3,
            nextAttemptAt: Date(timeIntervalSince1970: 1_700_000_500),
            lastError: "Server error (503)."
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SyncQueueEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
    }

    func test_codableRoundTrip_entryWithAllOptionalFieldsNil_preservesEquality() throws {
        // The common case: a rename entry only populates itemID/newName/previousName.
        let entry = SyncQueueEntry.renameFile(itemID: "f1", newName: "New", previousName: "Old")

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SyncQueueEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
    }
}
