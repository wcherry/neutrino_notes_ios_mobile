import XCTest
import Sodium
@testable import NeutrinoNotes

/// Tests for `OfflineStore`, the on-disk cache backing Epic 9 (Offline Editing). Every test
/// gets its own temp directory (never the real Application Support cache) and, where crypto is
/// involved, a real Curve25519 key pair in the Keychain plus a real `NoteContentService` — no
/// mocked crypto, mirroring `NoteContentServiceTests`.
///
/// Nothing here calls the network (`download`, `resolveKeepingServer`, `SyncEngine.syncNow`).
/// Notes are seeded directly onto disk in the exact on-disk layout `OfflineStore` documents at
/// the top of its own file (`index.json` + `<id>.bin`), which is enough to exercise every
/// non-network code path including the sync-engine callbacks.
@MainActor
final class OfflineStoreTests: XCTestCase {

    private let sodium = Sodium()
    private var tempDirectory: URL!
    private var content: NoteContentService!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        KeyImportService.removeKeys()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        content = NoteContentService()
    }

    override func tearDown() {
        super.tearDown()
        KeyImportService.removeKeys()
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        content = nil
    }

    // MARK: - Helpers

    /// Generates a real Curve25519 key pair and stores it in the Keychain under the same keys
    /// KeyImportService uses, exactly as NoteContentServiceTests does.
    @discardableResult
    private func storeRealKeyPair() -> Box.KeyPair {
        let keyPair = sodium.box.keyPair()!
        let pubB64 = sodium.utils.bin2base64(keyPair.publicKey, variant: .URLSAFE_NO_PADDING)!
        let privB64 = sodium.utils.bin2base64(keyPair.secretKey, variant: .URLSAFE_NO_PADDING)!
        _ = pubB64; _ = privB64
        KeyringStore.shared.store(Keyring(userId: KeyringTestSupport.testUserID, entries: [
            KeyringEntry(version: 1, publicKey: keyPair.publicKey, secretKey: keyPair.secretKey,
                         createdAt: "2026-08-20T00:00:00Z", retiredAt: nil)
        ]))
        return keyPair
    }

    private func makeStore() -> OfflineStore {
        let store = OfflineStore(directory: tempDirectory)
        store.noteContentService = content
        return store
    }

    /// Encrypts `text` and writes it straight to `<id>.bin` in the temp directory, returning the
    /// `OfflineNote` catalogue entry (not yet written to `index.json`) and the DEK used, so
    /// callers can seed a store's state without any network call. Requires `storeRealKeyPair()`
    /// to have been called first (needed for `sealDEK`).
    private func seedNote(
        id: String = UUID().uuidString,
        name: String = "Note.md",
        parentID: String? = nil,
        text: String = "hello world",
        serverModifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        pendingEdit: PendingEdit? = nil,
        conflict: Conflict? = nil
    ) throws -> (note: OfflineNote, dek: Bytes) {
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let ciphertext = try content.encrypt(text: text, dek: dek, xcss: xcss)
        try ciphertext.write(to: tempDirectory.appendingPathComponent("\(id).bin"))
        let sealedDEK = try content.sealDEK(dek)
        let note = OfflineNote(
            id: id, name: name, parentID: parentID, mimeType: NoteItem.markdownMIME,
            sealedDEK: sealedDEK.sealed, keyVersion: sealedDEK.keyVersion,
            serverModifiedAt: serverModifiedAt, cachedAt: Date(),
            sizeBytes: Int64(text.utf8.count), pendingEdit: pendingEdit, conflict: conflict
        )
        return (note, dek)
    }

    private func writeIndex(_ notes: [OfflineNote]) throws {
        let data = try JSONEncoder().encode(notes)
        try data.write(to: tempDirectory.appendingPathComponent("index.json"))
    }

    /// True if `needle` appears anywhere inside `haystack`, byte for byte. Used to assert that
    /// plaintext never touches disk — deliberately not relying on any higher-level Data search
    /// API so the check itself stays simple and obviously correct.
    private func containsSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let end = haystack.count - needle.count
        guard end >= 0 else { return false }
        for start in 0...end {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    // MARK: - writePendingEdit / readPlaintext round trip

    func test_writePendingEdit_thenReadPlaintext_roundTripsExactTextAndTakesPrecedenceOverBase() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base version")
        try writeIndex([note])
        let store = makeStore()

        let (baseText, readDEK) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(baseText, "base version")
        XCTAssertEqual(readDEK, dek)

        try store.writePendingEdit("edited version, offline", id: note.id, dek: readDEK)

        let (afterEdit, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(afterEdit, "edited version, offline")
    }

    func test_writePendingEdit_roundTripsUnicodeAndMultilineTextExactly() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()

        let distinctiveText = "# Café notes 🎉\n\nLine two\twith a tab.\n日本語テキストも。"
        try store.writePendingEdit(distinctiveText, id: note.id, dek: dek)

        let (text, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(text, distinctiveText)
    }

    // MARK: - Security invariant: nothing plaintext ever hits disk

    func test_writePendingEdit_neverWritesPlaintextBytesAnywhereInCacheDirectory() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "boring base body")
        try writeIndex([note])
        let store = makeStore()

        let marker = "TOTALLY-DISTINCTIVE-PLAINTEXT-MARKER-\(UUID().uuidString)"
        try store.writePendingEdit(marker, id: note.id, dek: dek)

        let needle = Array(marker.utf8)
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "sanity check: the cache directory should contain files to scan")

        for file in files {
            let bytes = try [UInt8](Data(contentsOf: file))
            XCTAssertFalse(
                containsSubsequence(needle, in: bytes),
                "found plaintext marker in \(file.lastPathComponent) — cache-at-rest must be ciphertext only"
            )
        }
    }

    // MARK: - baseServerModifiedAt is preserved across a chain of offline edits

    func test_writePendingEdit_successiveEdits_preserveOriginalBaseServerModifiedAtButAdvanceEditedAt() throws {
        storeRealKeyPair()
        let originalServerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "v1", serverModifiedAt: originalServerDate)
        try writeIndex([note])
        let store = makeStore()

        try store.writePendingEdit("v2", id: note.id, dek: dek)
        let firstEdit = try XCTUnwrap(store.note(id: note.id)?.pendingEdit)
        XCTAssertEqual(firstEdit.baseServerModifiedAt, originalServerDate)

        Thread.sleep(forTimeInterval: 0.01) // ensure the clock actually advances between writes

        try store.writePendingEdit("v3", id: note.id, dek: dek)
        let secondEdit = try XCTUnwrap(store.note(id: note.id)?.pendingEdit)

        XCTAssertEqual(secondEdit.baseServerModifiedAt, originalServerDate, "base must stay pinned to the version the chain started from")
        XCTAssertGreaterThan(secondEdit.editedAt, firstEdit.editedAt, "editedAt must advance with each edit")
    }

    // MARK: - remove / removeAll

    func test_remove_withPendingEdit_throwsHasPendingEditAndLeavesNoteInPlace() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        XCTAssertThrowsError(try store.remove(id: note.id)) { error in
            guard case OfflineStoreError.hasPendingEdit = error else {
                return XCTFail("Expected hasPendingEdit, got \(error)")
            }
        }
        XCTAssertNotNil(store.note(id: note.id))
    }

    func test_remove_withoutPendingEdit_deletesBaseBlobAndIndexEntry() throws {
        storeRealKeyPair()
        let (note, _) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()

        try store.remove(id: note.id)

        XCTAssertNil(store.note(id: note.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("\(note.id).bin").path))
    }

    func test_remove_unknownID_throwsNotCached() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.remove(id: "does-not-exist")) { error in
            guard case OfflineStoreError.notCached = error else {
                return XCTFail("Expected notCached, got \(error)")
            }
        }
    }

    func test_removeAll_skipsNotesWithPendingEditsButRemovesCleanOnes() throws {
        storeRealKeyPair()
        let (cleanNote, _) = try seedNote(id: "clean", text: "clean body")
        let (dirtyNote, dek) = try seedNote(id: "dirty", text: "dirty body")
        try writeIndex([cleanNote, dirtyNote])
        let store = makeStore()
        try store.writePendingEdit("dirty edit", id: dirtyNote.id, dek: dek)

        try store.removeAll()

        XCTAssertNil(store.note(id: "clean"))
        XCTAssertNotNil(store.note(id: "dirty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("clean.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("dirty.bin").path))
    }

    // MARK: - Index persistence across instances

    func test_index_persistsAcrossStoreInstances_withServerModifiedAtRoundTrippingExactly() throws {
        storeRealKeyPair()
        let serverDate = Date(timeIntervalSince1970: 1_700_123_456.789)
        let (note, dek) = try seedNote(text: "persisted", serverModifiedAt: serverDate)
        try writeIndex([note])

        let store1 = makeStore()
        try store1.writePendingEdit("edited before reopening", id: note.id, dek: dek)

        // A second store instance over the same directory must see exactly what the first wrote.
        let store2 = makeStore()
        let reloaded = try XCTUnwrap(store2.note(id: note.id))

        XCTAssertEqual(reloaded.serverModifiedAt, serverDate, "conflict detection depends on this round-tripping exactly")
        XCTAssertEqual(reloaded.name, note.name)
        XCTAssertNotNil(reloaded.pendingEdit)

        let (text, _) = try store2.readPlaintext(id: note.id)
        XCTAssertEqual(text, "edited before reopening")
    }

    // MARK: - Resilience

    func test_init_withCorruptIndexJSON_yieldsEmptyCatalogueRatherThanCrashing() throws {
        try Data("this is not valid json {{{".utf8).write(to: tempDirectory.appendingPathComponent("index.json"))

        let store = makeStore()

        XCTAssertTrue(store.notes.isEmpty)
    }

    func test_init_withNoIndexFileAtAll_startsWithEmptyCatalogue() {
        // tempDirectory exists but nothing has been written into it yet.
        let store = makeStore()

        XCTAssertTrue(store.notes.isEmpty)
    }

    func test_readPlaintext_unknownID_throwsNotCached() {
        let store = makeStore()

        XCTAssertThrowsError(try store.readPlaintext(id: "does-not-exist")) { error in
            guard case OfflineStoreError.notCached = error else {
                return XCTFail("Expected notCached, got \(error)")
            }
        }
    }

    func test_readPlaintext_withMissingBaseBlob_throwsNotCached() throws {
        storeRealKeyPair()
        let (note, _) = try seedNote(text: "body")
        try writeIndex([note])
        try FileManager.default.removeItem(at: tempDirectory.appendingPathComponent("\(note.id).bin"))

        let store = makeStore()

        XCTAssertThrowsError(try store.readPlaintext(id: note.id)) { error in
            guard case OfflineStoreError.notCached = error else {
                return XCTFail("Expected notCached, got \(error)")
            }
        }
    }

    // MARK: - clearPendingEdit

    func test_clearPendingEdit_promotesPendingBlobToBaseAndClearsQueueState() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited text", id: note.id, dek: dek)

        try store.clearPendingEdit(id: note.id, serverModifiedAt: Date(timeIntervalSince1970: 1_700_500_000))

        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(updated.pendingEdit)
        XCTAssertNil(updated.conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("\(note.id).pending.bin").path))

        let (text, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(text, "edited text", "the promoted base blob must still decrypt to the edited text")
    }

    // MARK: - recordFailure

    func test_recordFailure_bumpsAttemptCountRecordsErrorAndStampsLastAttemptAt() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        try store.recordFailure(id: note.id, error: "network timeout")

        let edit = try XCTUnwrap(store.note(id: note.id)?.pendingEdit)
        XCTAssertEqual(edit.attemptCount, 1)
        XCTAssertEqual(edit.lastError, "network timeout")
        XCTAssertNotNil(edit.lastAttemptAt)

        try store.recordFailure(id: note.id, error: "still failing")
        let secondEdit = try XCTUnwrap(store.note(id: note.id)?.pendingEdit)
        XCTAssertEqual(secondEdit.attemptCount, 2)
        XCTAssertEqual(secondEdit.lastError, "still failing")
    }

    func test_recordFailure_withoutPendingEdit_throwsNotCached() throws {
        storeRealKeyPair()
        let (note, _) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()

        XCTAssertThrowsError(try store.recordFailure(id: note.id, error: "boom")) { error in
            guard case OfflineStoreError.notCached = error else {
                return XCTFail("Expected notCached, got \(error)")
            }
        }
    }

    // MARK: - markConflict / resolveKeepingLocal

    func test_markConflictThenResolveKeepingLocal_rebasesOntoConflictDateResetsBackoffAndKeepsEdit() throws {
        storeRealKeyPair()
        let originalServerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "body", serverModifiedAt: originalServerDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited while offline", id: note.id, dek: dek)
        try store.recordFailure(id: note.id, error: "prior failure") // give attemptCount/lastAttemptAt something to reset

        let newerServerDate = Date(timeIntervalSince1970: 1_700_999_999)
        try store.markConflict(id: note.id, serverModifiedAt: newerServerDate)
        XCTAssertNotNil(store.note(id: note.id)?.conflict)

        try store.resolveKeepingLocal(id: note.id)

        let resolved = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(resolved.conflict)
        let edit = try XCTUnwrap(resolved.pendingEdit)
        XCTAssertEqual(edit.baseServerModifiedAt, newerServerDate)
        XCTAssertEqual(edit.attemptCount, 0)
        XCTAssertNil(edit.lastAttemptAt)
        XCTAssertNil(edit.lastError)

        // The pending edit's content itself must survive resolution untouched.
        let (text, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(text, "edited while offline")
    }

    func test_resolveKeepingLocal_withoutPendingEdit_throwsNotCached() throws {
        storeRealKeyPair()
        let (note, _) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()

        XCTAssertThrowsError(try store.resolveKeepingLocal(id: note.id)) { error in
            guard case OfflineStoreError.notCached = error else {
                return XCTFail("Expected notCached, got \(error)")
            }
        }
    }

    // MARK: - cacheLocalVersion

    func test_cacheLocalVersion_updatesBaseVersionAndServerModifiedAtWithoutDisturbingPendingEdit() throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("pending edit text", id: note.id, dek: dek)

        let newServerDate = Date(timeIntervalSince1970: 1_701_000_000)
        try store.cacheLocalVersion("new base text", id: note.id, dek: dek, serverModifiedAt: newServerDate)

        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.serverModifiedAt, newServerDate)
        XCTAssertNotNil(updated.pendingEdit, "an in-flight local edit must not be clobbered by a base-version refresh")

        // Pending edit still wins on read.
        let (text, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(text, "pending edit text")
    }

    // MARK: - Counters and simple queries

    func test_pendingCountAndConflictCount_reflectCurrentNoteState() throws {
        storeRealKeyPair()
        let (noteA, dekA) = try seedNote(id: "a", text: "a")
        let (noteB, dekB) = try seedNote(id: "b", text: "b")
        let (noteC, _) = try seedNote(id: "c", text: "c")
        try writeIndex([noteA, noteB, noteC])
        let store = makeStore()

        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.conflictCount, 0)

        try store.writePendingEdit("a edited", id: "a", dek: dekA)
        try store.writePendingEdit("b edited", id: "b", dek: dekB)
        XCTAssertEqual(store.pendingCount, 2)

        try store.markConflict(id: "b", serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(store.conflictCount, 1)
        XCTAssertEqual(store.pendingCount, 2, "a conflict does not clear the pending edit")
    }

    func test_isAvailableOffline_trueForCachedNoteFalseForUnknownID() throws {
        storeRealKeyPair()
        let (note, _) = try seedNote(text: "body")
        try writeIndex([note])
        let store = makeStore()

        XCTAssertTrue(store.isAvailableOffline(note.id))
        XCTAssertFalse(store.isAvailableOffline("unknown-id"))
    }

    func test_totalBytesOnDisk_sumsOnlyBinFileSizesAndIgnoresIndex() throws {
        storeRealKeyPair()
        let (noteA, _) = try seedNote(id: "a", text: "short")
        let (noteB, _) = try seedNote(id: "b", text: "a somewhat longer piece of body text")
        try writeIndex([noteA, noteB])
        let store = makeStore()

        let expected: Int64 = try ["a.bin", "b.bin"].reduce(into: 0) { total, name in
            let path = tempDirectory.appendingPathComponent(name).path
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
            total += size
        }

        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(store.totalBytesOnDisk, expected)
    }

    func test_totalBytesOnDisk_withEmptyCache_isZero() {
        let store = makeStore()

        XCTAssertEqual(store.totalBytesOnDisk, 0)
    }

    // MARK: - rebasePendingEdit (Epic 12)

    /// Renaming or starring a note bumps the server's `updated_at` without changing its content.
    /// Left alone, SyncEngine would read that bump as somebody else's edit and raise a conflict
    /// over the user's own text.
    func test_rebasePendingEdit_movesTheEditsBaseOntoTheMetadataWritesTimestamp() throws {
        storeRealKeyPair()
        let originalServerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "body", serverModifiedAt: originalServerDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited while offline", id: note.id, dek: dek)

        let afterMetadataWrite = Date(timeIntervalSince1970: 1_700_000_500)
        store.rebasePendingEdit(id: note.id,
                                previousModifiedAt: originalServerDate,
                                serverModifiedAt: afterMetadataWrite)

        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.serverModifiedAt, afterMetadataWrite)
        XCTAssertEqual(updated.pendingEdit?.baseServerModifiedAt, afterMetadataWrite)
    }

    func test_rebasePendingEdit_withoutAPendingEdit_stillRecordsTheNewServerVersion() throws {
        storeRealKeyPair()
        let originalServerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, _) = try seedNote(text: "body", serverModifiedAt: originalServerDate)
        try writeIndex([note])
        let store = makeStore()

        let afterMetadataWrite = Date(timeIntervalSince1970: 1_700_000_500)
        store.rebasePendingEdit(id: note.id,
                                previousModifiedAt: originalServerDate,
                                serverModifiedAt: afterMetadataWrite)

        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.serverModifiedAt, afterMetadataWrite)
        XCTAssertNil(updated.pendingEdit)
    }

    /// A genuine remote content edit must still conflict: if the cache already knows about a
    /// version at or beyond the one the metadata write was based on, the rebase is skipped.
    func test_rebasePendingEdit_isSkippedWhenTheCacheAlreadyKnowsSomethingNewer() throws {
        storeRealKeyPair()
        let cachedServerDate = Date(timeIntervalSince1970: 1_700_000_900)
        let (note, dek) = try seedNote(text: "body", serverModifiedAt: cachedServerDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited while offline", id: note.id, dek: dek)

        // The metadata write was made against a version older than the one the cache holds.
        store.rebasePendingEdit(id: note.id,
                                previousModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_950))

        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.serverModifiedAt, cachedServerDate)
        XCTAssertEqual(updated.pendingEdit?.baseServerModifiedAt, cachedServerDate)
    }

    func test_rebasePendingEdit_withAnOlderTimestamp_doesNothing() throws {
        storeRealKeyPair()
        let cachedServerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, _) = try seedNote(text: "body", serverModifiedAt: cachedServerDate)
        try writeIndex([note])
        let store = makeStore()

        store.rebasePendingEdit(id: note.id,
                                previousModifiedAt: cachedServerDate,
                                serverModifiedAt: Date(timeIntervalSince1970: 1_699_000_000))

        XCTAssertEqual(store.note(id: note.id)?.serverModifiedAt, cachedServerDate)
    }

    func test_rebasePendingEdit_unknownID_isANoOp() {
        let store = makeStore()

        store.rebasePendingEdit(id: "not-cached",
                                previousModifiedAt: Date(timeIntervalSince1970: 1),
                                serverModifiedAt: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(store.notes.isEmpty)
    }
}
