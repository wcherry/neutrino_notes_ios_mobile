import XCTest
import Sodium
@testable import NeutrinoNotes

// MARK: - FakeSyncError

/// A distinctive, deterministic error for scripting failures on the fake — its `errorDescription`
/// is what ends up in `SyncEngine.State.failed(_:)` and in `PendingEdit.lastError`.
private struct FakeSyncError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - FakeNoteSyncing

/// Test double for `NoteSyncing` — the seam that lets `SyncEngine`'s drain loop be driven with no
/// network at all. Every call is recorded (id and, for uploads, the exact text) so tests can
/// assert not just outcomes but *whether an upload was attempted in the first place* — the crux
/// of the conflict-detection guarantee.
@MainActor
private final class FakeNoteSyncing: NoteSyncing {

    enum FetchResult {
        case value(Date?)
        case failure(Error)
    }

    enum SaveResult {
        case value(Date)
        case failure(Error)
    }

    /// Per-id overrides; falls back to the default when a note's id isn't present.
    var fetchServerModifiedAtResult: [String: FetchResult] = [:]
    var defaultFetchServerModifiedAtResult: FetchResult = .value(nil)

    var saveContentResult: [String: SaveResult] = [:]
    var defaultSaveContentResult: SaveResult = .value(Date())

    private(set) var fetchCalls: [String] = []
    private(set) var saveCalls: [(id: String, text: String)] = []

    func fetchServerModifiedAt(for item: NoteItem) async throws -> Date? {
        fetchCalls.append(item.id)
        switch fetchServerModifiedAtResult[item.id] ?? defaultFetchServerModifiedAtResult {
        case .value(let date): return date
        case .failure(let error): throw error
        }
    }

    func saveContent(_ text: String, for item: NoteItem, dek: Bytes) async throws -> Date {
        saveCalls.append((id: item.id, text: text))
        switch saveContentResult[item.id] ?? defaultSaveContentResult {
        case .value(let date): return date
        case .failure(let error): throw error
        }
    }
}

// MARK: - SyncEngineTests

/// Tests for `SyncEngine`'s drain loop — the safety-critical piece of Epic 9 (Offline Editing)
/// that decides whether a queued offline edit is uploaded or flagged as a conflict. Driven
/// entirely through the `NoteSyncing` seam (`FakeNoteSyncing` above) and `NetworkMonitor`'s
/// `autoStart: false` / `setOnlineForTesting(_:)` test hook — no network, no real HTTP.
///
/// Setup mirrors `OfflineStoreTests` exactly: a unique temp directory per test, a real
/// `NoteContentService` for crypto, and a real Curve25519 key pair in the Keychain so the store's
/// encrypt/decrypt paths (which the drain loop exercises via `readPlaintext`) behave exactly as
/// they do in the app.
@MainActor
final class SyncEngineTests: XCTestCase {

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
    /// KeyImportService uses — identical to `OfflineStoreTests.storeRealKeyPair()`.
    @discardableResult
    private func storeRealKeyPair() -> Box.KeyPair {
        let keyPair = sodium.box.keyPair()!
        let pubB64 = sodium.utils.bin2base64(keyPair.publicKey, variant: .URLSAFE_NO_PADDING)!
        let privB64 = sodium.utils.bin2base64(keyPair.secretKey, variant: .URLSAFE_NO_PADDING)!
        KeychainService.save(pubB64, forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save(privB64, forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1", forKey: KeyImportService.keyVersionKeychainKey)
        return keyPair
    }

    private func makeStore() -> OfflineStore {
        let store = OfflineStore(directory: tempDirectory)
        store.noteContentService = content
        return store
    }

    /// Encrypts `text` and writes it straight to `<id>.bin`, returning the catalogue entry (not
    /// yet written to `index.json`) and the DEK — same convention as `OfflineStoreTests.seedNote`.
    private func seedNote(
        id: String = UUID().uuidString,
        name: String = "Note.md",
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
            id: id, name: name, parentID: nil, mimeType: NoteItem.markdownMIME,
            sealedDEK: sealedDEK, serverModifiedAt: serverModifiedAt, cachedAt: Date(),
            sizeBytes: Int64(text.utf8.count), pendingEdit: pendingEdit, conflict: conflict
        )
        return (note, dek)
    }

    private func writeIndex(_ notes: [OfflineNote]) throws {
        let data = try JSONEncoder().encode(notes)
        try data.write(to: tempDirectory.appendingPathComponent("index.json"))
    }

    private func makeOnlineEngine(store: OfflineStore, fake: FakeNoteSyncing) -> (SyncEngine, NetworkMonitor) {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(true)
        let engine = SyncEngine(store: store, monitor: monitor, content: fake)
        return (engine, monitor)
    }

    // MARK: - Conflict detection

    func test_drain_serverStrictlyNewerThanBase_marksConflictNeverUploadsAndKeepsPendingEditIntact() async throws {
        storeRealKeyPair()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base version", serverModifiedAt: baseDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited while offline", id: note.id, dek: dek)

        let serverNewerDate = baseDate.addingTimeInterval(100)
        let fake = FakeNoteSyncing()
        fake.defaultFetchServerModifiedAtResult = .value(serverNewerDate)
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.count, 0, "must never upload once the server has moved ahead of the edit's base version")
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.conflict?.serverModifiedAt, serverNewerDate)
        XCTAssertNotNil(updated.pendingEdit, "the pending edit must survive being flagged as a conflict")
        let (text, _) = try store.readPlaintext(id: note.id)
        XCTAssertEqual(text, "edited while offline", "the queued edit itself must be untouched by conflict detection")
    }

    func test_drain_serverEqualToBase_uploadsRatherThanFlaggingConflict() async throws {
        storeRealKeyPair()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base", serverModifiedAt: baseDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        fake.defaultFetchServerModifiedAtResult = .value(baseDate) // exactly equal
        let uploadedAt = baseDate.addingTimeInterval(50)
        fake.defaultSaveContentResult = .value(uploadedAt)
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.count, 1)
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(updated.conflict)
        XCTAssertNil(updated.pendingEdit)
    }

    func test_drain_serverOlderThanBase_uploadsRatherThanFlaggingConflict() async throws {
        storeRealKeyPair()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base", serverModifiedAt: baseDate)
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        fake.defaultFetchServerModifiedAtResult = .value(baseDate.addingTimeInterval(-50)) // older
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.count, 1)
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(updated.conflict)
        XCTAssertNil(updated.pendingEdit)
    }

    /// Documents current behaviour rather than asserting it is necessarily desirable: if the
    /// server-side lookup comes back `nil` (e.g. the file is gone server-side), the drain loop
    /// treats that as "not a conflict" and attempts the upload anyway.
    func test_drain_fetchServerModifiedAtReturnsNil_isTreatedAsNotAConflictAndUploadIsAttempted() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        fake.defaultFetchServerModifiedAtResult = .value(nil)
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.count, 1, "current behaviour: a nil server date does not block the upload")
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(updated.conflict)
    }

    func test_drain_noteAlreadyConflicted_isSkippedEntirelyWithNoFetchAndNoUpload() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)
        try store.markConflict(id: note.id, serverModifiedAt: Date(timeIntervalSince1970: 1_700_999_999))

        let fake = FakeNoteSyncing()
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertTrue(fake.fetchCalls.isEmpty, "an already-conflicted note must not even be looked up")
        XCTAssertTrue(fake.saveCalls.isEmpty)
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNotNil(updated.conflict, "the conflict flag must remain until the user resolves it")
        XCTAssertNotNil(updated.pendingEdit)
    }

    // MARK: - Happy path

    func test_drain_successfulUpload_sendsPendingTextClearsQueueUpdatesServerDateAndEndsIdle() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "stale base text")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("fresh pending text", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        let uploadedAt = Date(timeIntervalSince1970: 1_701_234_567)
        fake.defaultSaveContentResult = .value(uploadedAt)
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        XCTAssertNil(engine.lastSyncedAt)
        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.map(\.text), ["fresh pending text"], "must upload the pending edit, not the stale cached base text")
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertNil(updated.pendingEdit)
        XCTAssertEqual(updated.serverModifiedAt, uploadedAt)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNotNil(engine.lastSyncedAt)
    }

    func test_drain_multipleQueuedNotes_processesOldestEditedAtFirst() async throws {
        storeRealKeyPair()
        let (noteA, dekA) = try seedNote(id: "note-a", text: "a base")
        let (noteB, dekB) = try seedNote(id: "note-b", text: "b base")
        try writeIndex([noteA, noteB])
        let store = makeStore()

        // note-b is edited first (so it must drain first), note-a second.
        try store.writePendingEdit("b edit", id: "note-b", dek: dekB)
        Thread.sleep(forTimeInterval: 0.05) // ensure editedAt actually advances between writes
        try store.writePendingEdit("a edit", id: "note-a", dek: dekA)

        let fake = FakeNoteSyncing()
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.fetchCalls, ["note-b", "note-a"])
        XCTAssertEqual(fake.saveCalls.map(\.id), ["note-b", "note-a"])
    }

    func test_drain_emptyQueue_leavesStateIdleAndStampsLastSyncedAt() async throws {
        let store = makeStore() // no notes at all
        let fake = FakeNoteSyncing()
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        XCTAssertNil(engine.lastSyncedAt)
        await engine.syncNow()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertNotNil(engine.lastSyncedAt)
        XCTAssertTrue(fake.fetchCalls.isEmpty)
        XCTAssertTrue(fake.saveCalls.isEmpty)
    }

    // MARK: - Failure and backoff

    func test_drain_saveContentThrows_recordsFailureKeepsPendingEditAndEndsFailed() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        let failure = FakeSyncError(message: "simulated upload failure")
        fake.defaultSaveContentResult = .failure(failure)
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        let updated = try XCTUnwrap(store.note(id: note.id))
        let edit = try XCTUnwrap(updated.pendingEdit, "a failed upload must not lose the pending edit")
        XCTAssertEqual(edit.attemptCount, 1)
        XCTAssertEqual(edit.lastError, failure.message)
        XCTAssertNotNil(edit.lastAttemptAt)

        guard case .failed(let message) = engine.state else {
            return XCTFail("expected .failed, got \(engine.state)")
        }
        XCTAssertEqual(message, failure.message)
    }

    func test_drain_oneNoteFailing_stillUploadsTheOtherQueuedNoteInTheSameDrain() async throws {
        storeRealKeyPair()
        let (noteA, dekA) = try seedNote(id: "note-a", text: "a base")
        let (noteB, dekB) = try seedNote(id: "note-b", text: "b base")
        try writeIndex([noteA, noteB])
        let store = makeStore()
        try store.writePendingEdit("a edit", id: "note-a", dek: dekA) // edited first, drains first
        Thread.sleep(forTimeInterval: 0.05)
        try store.writePendingEdit("b edit", id: "note-b", dek: dekB)

        let fake = FakeNoteSyncing()
        fake.saveContentResult["note-a"] = .failure(FakeSyncError(message: "note-a failed"))
        fake.saveContentResult["note-b"] = .value(Date(timeIntervalSince1970: 1_701_000_000))
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertEqual(fake.saveCalls.map(\.id), ["note-a", "note-b"], "both notes must be attempted despite the first failing")
        XCTAssertNotNil(store.note(id: "note-a")?.pendingEdit, "note-a's edit must survive its failure")
        XCTAssertNil(store.note(id: "note-b")?.pendingEdit, "note-b must still succeed even though note-a failed")
        guard case .failed = engine.state else {
            return XCTFail("expected .failed since one note in the drain failed, got \(engine.state)")
        }
    }

    func test_drain_noteInsideBackoffWindow_isSkipped() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)
        // attemptCount becomes 1, lastAttemptAt becomes ~now — nextAttemptAt is ~5s in the future
        // (SyncBackoff.delay(forAttempt: 1) == 5), well past "now" for the duration of this test.
        try store.recordFailure(id: note.id, error: "prior failure")

        let fake = FakeNoteSyncing()
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        await engine.syncNow()

        XCTAssertTrue(fake.fetchCalls.isEmpty, "a note still inside its backoff window must not even be looked up")
        XCTAssertTrue(fake.saveCalls.isEmpty)
        XCTAssertNotNil(store.note(id: note.id)?.pendingEdit, "the edit must remain queued, untouched, until the backoff elapses")
    }

    // MARK: - Connectivity and re-entrancy

    func test_syncNow_whileOffline_setsOfflineStateAndTouchesNothing() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)
        let engine = SyncEngine(store: store, monitor: monitor, content: fake)

        await engine.syncNow()

        XCTAssertEqual(engine.state, .offline)
        XCTAssertTrue(fake.fetchCalls.isEmpty)
        XCTAssertTrue(fake.saveCalls.isEmpty)
        XCTAssertNotNil(store.note(id: note.id)?.pendingEdit, "an offline drain attempt must not touch the queue")
        XCTAssertNil(engine.lastSyncedAt)
    }

    func test_syncNow_twoOverlappingCalls_joinTheSameDrainSoUploadHappensOnlyOnce() async throws {
        storeRealKeyPair()
        let (note, dek) = try seedNote(text: "base")
        try writeIndex([note])
        let store = makeStore()
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let fake = FakeNoteSyncing()
        let (engine, _) = makeOnlineEngine(store: store, fake: fake)

        // Both calls are made without any intervening suspension point, so — per the re-entrancy
        // guard's own contract ("the body cannot start before inFlight is set") — the second call
        // must join the first's in-flight task rather than starting a second drain.
        async let first: Void = engine.syncNow()
        async let second: Void = engine.syncNow()
        _ = await (first, second)

        XCTAssertEqual(fake.saveCalls.count, 1, "two overlapping syncNow() calls must result in a single drain")
        XCTAssertNil(store.note(id: note.id)?.pendingEdit)
    }
}
