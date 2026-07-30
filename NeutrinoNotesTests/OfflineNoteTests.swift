import XCTest
@testable import NeutrinoNotes

/// Tests for the pure model types backing Epic 9 (Offline Editing): `OfflineNote`,
/// `PendingEdit`, `Conflict`, and `SyncBackoff`. No I/O, no crypto, no clock — these are
/// straightforward value-type and pure-function tests.
@MainActor
final class OfflineNoteTests: XCTestCase {

    // MARK: - SyncBackoff.delay

    func test_syncBackoffDelay_forAttemptZero_isZero() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 0), 0)
    }

    func test_syncBackoffDelay_forNegativeAttempt_isZero() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: -1), 0)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: -100), 0)
    }

    func test_syncBackoffDelay_growsExponentiallyThroughFirstFourAttempts() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 1), 5)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 2), 15)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 3), 45)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 4), 135)
    }

    func test_syncBackoffDelay_isCappedAtMaximumDelayForLargeAttemptCounts() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 5), SyncBackoff.maximumDelay)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 20), SyncBackoff.maximumDelay)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 1000), SyncBackoff.maximumDelay)
    }

    // MARK: - PendingEdit.nextAttemptAt

    func test_pendingEditNextAttemptAt_withLastAttemptAt_isMeasuredFromLastAttempt() {
        let editedAt = Date(timeIntervalSince1970: 1_000)
        let lastAttemptAt = Date(timeIntervalSince1970: 5_000)
        let edit = PendingEdit(
            editedAt: editedAt, baseServerModifiedAt: editedAt,
            attemptCount: 1, lastError: "boom", lastAttemptAt: lastAttemptAt
        )

        XCTAssertEqual(edit.nextAttemptAt, lastAttemptAt.addingTimeInterval(SyncBackoff.delay(forAttempt: 1)))
    }

    func test_pendingEditNextAttemptAt_withoutLastAttemptAt_fallsBackToEditedAt() {
        let editedAt = Date(timeIntervalSince1970: 1_000)
        let edit = PendingEdit(
            editedAt: editedAt, baseServerModifiedAt: editedAt,
            attemptCount: 0, lastError: nil, lastAttemptAt: nil
        )

        // attempt 0 delay is zero, so nextAttemptAt should land exactly on editedAt.
        XCTAssertEqual(edit.nextAttemptAt, editedAt)
    }

    func test_pendingEditNextAttemptAt_withoutLastAttemptAt_stillAppliesBackoffForNonZeroAttempt() {
        let editedAt = Date(timeIntervalSince1970: 1_000)
        let edit = PendingEdit(
            editedAt: editedAt, baseServerModifiedAt: editedAt,
            attemptCount: 2, lastError: "boom", lastAttemptAt: nil
        )

        XCTAssertEqual(edit.nextAttemptAt, editedAt.addingTimeInterval(SyncBackoff.delay(forAttempt: 2)))
    }

    // MARK: - OfflineNote.asNoteItem

    func test_asNoteItem_mapsFieldsCorrectly() {
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let note = OfflineNote(
            id: "note-1", name: "Groceries.md", parentID: "folder-1",
            mimeType: "text/custom", sealedDEK: "sealed", serverModifiedAt: modifiedAt,
            cachedAt: Date(), sizeBytes: 42, pendingEdit: nil, conflict: nil
        )

        let item = note.asNoteItem

        XCTAssertEqual(item.id, "note-1")
        XCTAssertEqual(item.name, "Groceries.md")
        XCTAssertEqual(item.type, .file)
        XCTAssertEqual(item.parentID, "folder-1")
        XCTAssertEqual(item.size, 42)
        XCTAssertEqual(item.modifiedAt, modifiedAt)
        XCTAssertFalse(item.isTrashed)
        XCTAssertEqual(item.mimeType, "text/custom")
    }

    func test_asNoteItem_withNilMimeType_defaultsToMarkdownMIME() {
        let note = OfflineNote(
            id: "note-2", name: "Untitled.md", parentID: nil,
            mimeType: nil, sealedDEK: "sealed", serverModifiedAt: Date(),
            cachedAt: Date(), sizeBytes: 0, pendingEdit: nil, conflict: nil
        )

        XCTAssertEqual(note.asNoteItem.mimeType, NoteItem.markdownMIME)
    }

    // MARK: - Codable round trip

    func test_offlineNoteCodableRoundTrip_preservesAllDatesExactly() throws {
        let serverModifiedAt = Date(timeIntervalSince1970: 1_700_123_456.789)
        let cachedAt = Date(timeIntervalSince1970: 1_700_223_456.123)
        let editedAt = Date(timeIntervalSince1970: 1_700_323_456.456)
        let lastAttemptAt = Date(timeIntervalSince1970: 1_700_423_456.999)
        let detectedAt = Date(timeIntervalSince1970: 1_700_523_456.111)
        let conflictServerDate = Date(timeIntervalSince1970: 1_700_623_456.222)

        let note = OfflineNote(
            id: "note-3", name: "Roundtrip.md", parentID: "folder-9",
            mimeType: NoteItem.markdownMIME, sealedDEK: "sealed-dek",
            serverModifiedAt: serverModifiedAt, cachedAt: cachedAt, sizeBytes: 1234,
            pendingEdit: PendingEdit(
                editedAt: editedAt, baseServerModifiedAt: serverModifiedAt,
                attemptCount: 2, lastError: "timeout", lastAttemptAt: lastAttemptAt
            ),
            conflict: Conflict(detectedAt: detectedAt, serverModifiedAt: conflictServerDate)
        )

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(OfflineNote.self, from: data)

        XCTAssertEqual(decoded, note)
        XCTAssertEqual(decoded.serverModifiedAt, serverModifiedAt)
        XCTAssertEqual(decoded.cachedAt, cachedAt)
        XCTAssertEqual(decoded.pendingEdit?.editedAt, editedAt)
        XCTAssertEqual(decoded.pendingEdit?.lastAttemptAt, lastAttemptAt)
        XCTAssertEqual(decoded.conflict?.detectedAt, detectedAt)
        XCTAssertEqual(decoded.conflict?.serverModifiedAt, conflictServerDate)
    }

    func test_offlineNoteCodableRoundTrip_withNilPendingEditAndConflict_decodesAsNil() throws {
        let note = OfflineNote(
            id: "note-4", name: "Clean.md", parentID: nil,
            mimeType: NoteItem.markdownMIME, sealedDEK: "sealed",
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_000), cachedAt: Date(timeIntervalSince1970: 1_700_000_001),
            sizeBytes: 10, pendingEdit: nil, conflict: nil
        )

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(OfflineNote.self, from: data)

        XCTAssertNil(decoded.pendingEdit)
        XCTAssertNil(decoded.conflict)
        XCTAssertEqual(decoded, note)
    }
}
