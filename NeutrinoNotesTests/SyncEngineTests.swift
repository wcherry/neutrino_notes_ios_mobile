import XCTest
@testable import NeutrinoNotes

/// Tests for `SyncEngine` — the retry-queue drain loop, backoff scheduling, permanent-failure
/// handling, conflict detection, and conflict resolution. All network I/O is faked via
/// `FakeSyncExecutor` (a `SyncOperationExecuting` conforming test double defined below); every
/// engine is constructed with a `SyncPersistence` pointed at a fresh temporary directory (never
/// the real Application Support path) and a fixed/advanceable `clock` closure so timing
/// assertions are fully deterministic.
@MainActor
final class SyncEngineTests: XCTestCase {

    // MARK: - Lifecycle

    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        if let tempDirectoryURL, FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makePersistence() -> SyncPersistence {
        SyncPersistence(directoryURL: tempDirectoryURL)
    }

    private func makeRenameEntry(itemID: String = "f1") -> SyncQueueEntry {
        SyncQueueEntry.renameFile(itemID: itemID, newName: "New Name", previousName: "Old Name")
    }

    // MARK: - enqueue

    func test_enqueue_incrementsPendingCount() {
        let engine = SyncEngine(persistence: makePersistence(), executor: FakeSyncExecutor(),
                                 clock: { Date(timeIntervalSince1970: 0) })

        engine.enqueue(makeRenameEntry())

        XCTAssertEqual(engine.pendingCount, 1)
    }

    func test_enqueue_persistsEntryToDiskImmediately() {
        let engine = SyncEngine(persistence: makePersistence(), executor: FakeSyncExecutor(),
                                 clock: { Date(timeIntervalSince1970: 0) })
        let entry = makeRenameEntry()

        engine.enqueue(entry)

        // A second, independent SyncPersistence pointed at the same directory proves the write
        // happened durably on disk, not just in the in-memory queueSnapshot.
        let reloaded = SyncPersistence(directoryURL: tempDirectoryURL).loadQueue()
        XCTAssertEqual(reloaded, [entry])
    }

    // MARK: - runSync: successful drain

    func test_runSync_entrySucceeds_drainsFromQueueAndClearsPendingCount() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let entry = makeRenameEntry()
        engine.enqueue(entry)

        await engine.runSync()

        XCTAssertEqual(fake.performCalls.map(\.id), [entry.id])
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    // MARK: - runSync: retryable failure & backoff

    func test_runSync_retryableFailure_incrementsAttemptCountAndSchedulesBackoffFromClock() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.networkError(underlying: DummyError()))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = SyncEngine(persistence: makePersistence(), executor: fake, clock: { now })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()

        guard let updated = engine.queueSnapshot.first else {
            return XCTFail("Expected the retryable-failure entry to remain queued")
        }
        XCTAssertEqual(updated.attemptCount, 1)
        let expectedBackoff = SyncQueueEntry.backoffInterval(forAttempt: updated.attemptCount)
        XCTAssertEqual(updated.nextAttemptAt.timeIntervalSince(now), expectedBackoff, accuracy: 0.001)
    }

    func test_runSync_serverError503_isTreatedAsRetryable() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 503))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()

        XCTAssertEqual(engine.queueSnapshot.first?.attemptCount, 1)
        XCTAssertTrue(engine.failedEntries.isEmpty)
    }

    func test_runSync_entryNotYetDue_isNotReattempted() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 503))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = SyncEngine(persistence: makePersistence(), executor: fake, clock: { now })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()
        let callsAfterFirstFailure = fake.performCalls.count
        XCTAssertEqual(callsAfterFirstFailure, 1)

        // Same clock reading — nextAttemptAt (now + backoff) is still in the future, so the
        // entry must not be attempted again.
        await engine.runSync()

        XCTAssertEqual(fake.performCalls.count, callsAfterFirstFailure)
    }

    func test_runSync_retryableFailureRepeatedToMaxAttempts_movesEntryToFailedEntries() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 503))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake, clock: { clock.now })
        let entry = makeRenameEntry()
        engine.enqueue(entry)

        for _ in 0..<SyncQueueEntry.maxAttempts {
            clock.now = clock.now.addingTimeInterval(20 * 60) // past the 15-minute backoff cap
            await engine.runSync()
        }

        XCTAssertEqual(fake.performCalls.count, SyncQueueEntry.maxAttempts)
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.failedEntries.map(\.id), [entry.id])
    }

    func test_runSync_afterEntryExhaustsMaxAttempts_doesNotAutoRetryIt() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 503))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake, clock: { clock.now })
        engine.enqueue(makeRenameEntry())

        for _ in 0..<SyncQueueEntry.maxAttempts {
            clock.now = clock.now.addingTimeInterval(20 * 60)
            await engine.runSync()
        }
        let callsAfterExhaustion = fake.performCalls.count

        clock.now = clock.now.addingTimeInterval(20 * 60)
        await engine.runSync()

        XCTAssertEqual(fake.performCalls.count, callsAfterExhaustion)
    }

    // MARK: - runSync: non-retryable failure

    func test_runSync_nonRetryableServerError_removesEntryWithoutRetryingAndSetsLastError() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 404))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()

        XCTAssertTrue(engine.queueSnapshot.isEmpty)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertNotNil(engine.lastError)
    }

    func test_runSync_nonRetryableFailure_doesNotAppearInFailedEntries() async {
        // failedEntries is specifically for entries that exhausted maxAttempts retries — a
        // non-retryable failure (decoding error) is dropped on the first attempt, not queued
        // for retry, so it must never land in failedEntries.
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.decodingError(underlying: DummyError()))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()

        XCTAssertTrue(engine.failedEntries.isEmpty)
    }

    func test_runSync_notAuthenticatedFailure_isTreatedAsNonRetryable() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.notAuthenticated)
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        engine.enqueue(makeRenameEntry())

        await engine.runSync()

        XCTAssertTrue(engine.queueSnapshot.isEmpty)
        XCTAssertTrue(engine.failedEntries.isEmpty)
    }

    // MARK: - retryNow

    func test_retryNow_onFailedEntry_attemptsAgainRegardlessOfScheduleAndClearsItOnSuccess() async {
        let fake = FakeSyncExecutor()
        fake.defaultPerformResult = .failure(NotesDriveError.serverError(statusCode: 503))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake, clock: { clock.now })
        let entry = makeRenameEntry()
        engine.enqueue(entry)

        for _ in 0..<SyncQueueEntry.maxAttempts {
            clock.now = clock.now.addingTimeInterval(20 * 60)
            await engine.runSync()
        }
        XCTAssertEqual(engine.failedEntries.count, 1)
        let failedEntry = engine.failedEntries[0]
        let callsBeforeRetry = fake.performCalls.count

        // Clock is NOT advanced before retryNow — proves the manual retry ignores
        // nextAttemptAt/attemptCount entirely, unlike the automatic runSync() path.
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        await engine.retryNow(failedEntry)

        XCTAssertEqual(fake.performCalls.count, callsBeforeRetry + 1)
        XCTAssertTrue(engine.failedEntries.isEmpty)
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
    }

    // MARK: - Conflict detection

    func test_runSync_saveNoteContentEntry_serverModifiedAfterBase_raisesConflictAndLeavesEntryQueued() async {
        let fake = FakeSyncExecutor()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let serverTime = baseTime.addingTimeInterval(60) // server has moved on since this save was staged
        fake.currentModifiedAtResults["f1"] = serverTime
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { baseTime.addingTimeInterval(120) })
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: baseTime
        )
        engine.enqueue(entry)

        await engine.runSync()

        XCTAssertEqual(engine.conflicts.count, 1)
        XCTAssertEqual(engine.conflicts.first?.itemID, "f1")
        XCTAssertEqual(engine.conflicts.first?.serverModifiedAt, serverTime)
        XCTAssertTrue(fake.performCalls.isEmpty, "The conflicting entry must not be drained via perform(_:)")
        XCTAssertEqual(engine.queueSnapshot.map(\.id), [entry.id], "The entry must stay queued, unresolved")
    }

    func test_runSync_saveNoteContentEntry_baseModifiedAtNil_drainsNormallyWithoutConflict() async {
        let fake = FakeSyncExecutor()
        fake.currentModifiedAtResults["f1"] = Date(timeIntervalSince1970: 1_700_000_060)
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_120) })
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: nil
        )
        engine.enqueue(entry)

        await engine.runSync()

        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertEqual(fake.performCalls.map(\.id), [entry.id])
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
    }

    func test_runSync_saveNoteContentEntry_baseModifiedAtMatchesServer_drainsNormallyWithoutConflict() async {
        let fake = FakeSyncExecutor()
        let serverTime = Date(timeIntervalSince1970: 1_700_000_060)
        fake.currentModifiedAtResults["f1"] = serverTime
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_120) })
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: serverTime
        )
        engine.enqueue(entry)

        await engine.runSync()

        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertEqual(fake.performCalls.map(\.id), [entry.id])
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
    }

    func test_runSync_saveNoteContentEntry_baseModifiedAtAfterServer_drainsNormallyWithoutConflict() async {
        let fake = FakeSyncExecutor()
        let serverTime = Date(timeIntervalSince1970: 1_700_000_060)
        fake.currentModifiedAtResults["f1"] = serverTime
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_120) })
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: serverTime.addingTimeInterval(30)
        )
        engine.enqueue(entry)

        await engine.runSync()

        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertEqual(fake.performCalls.map(\.id), [entry.id])
        XCTAssertTrue(engine.queueSnapshot.isEmpty)
    }

    // MARK: - resolve

    /// Builds an engine that already has exactly one active SyncConflict, via the same
    /// queue-drain detection path exercised above, so resolve() tests don't need to construct
    /// a SyncConflict by hand.
    private func makeEngineWithActiveConflict() async -> (engine: SyncEngine, fake: FakeSyncExecutor, conflict: SyncConflict) {
        let fake = FakeSyncExecutor()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let serverTime = baseTime.addingTimeInterval(60)
        fake.currentModifiedAtResults["f1"] = serverTime
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { baseTime.addingTimeInterval(120) })
        let entry = SyncQueueEntry.saveNoteContent(
            itemID: "f1", encryptedContentBase64: "cGxhaW50ZXh0", fileName: "Note.md",
            mimeType: NoteItem.markdownMIME, baseModifiedAt: baseTime
        )
        engine.enqueue(entry)
        await engine.runSync()
        guard let conflict = engine.conflicts.first else {
            fatalError("Test setup failed: runSync() did not raise the expected conflict")
        }
        return (engine, fake, conflict)
    }

    func test_resolve_keepMine_queuedCiphertext_clearsConflictAndDoesNotPopulateOutcomeFields() async throws {
        let (engine, fake, conflict) = await makeEngineWithActiveConflict()
        fake.defaultPerformResult = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))

        let outcome = try await engine.resolve(conflict, choice: .keepMine, localSource: .queuedCiphertext)

        XCTAssertTrue(engine.conflicts.isEmpty)
        // Keep Mine overwrites the server with what the caller already has locally — there is
        // nothing new for the caller to display, so neither outcome field should be populated.
        XCTAssertNil(outcome.updatedLocalText)
        XCTAssertNil(outcome.forkedItem)
    }

    func test_resolve_keepServer_withoutNoteContentServiceWired_throwsAndLeavesConflictUnresolved() async {
        // Keep Server must fetch and decrypt the server's copy via NoteContentService — there is
        // no seam for that on SyncOperationExecuting, so with noteContentService left unwired
        // (as in every other test in this file, to stay off the network) resolve() cannot
        // succeed and must throw rather than silently no-op or fabricate a result.
        let (engine, _, conflict) = await makeEngineWithActiveConflict()
        XCTAssertNil(engine.noteContentService)

        do {
            _ = try await engine.resolve(conflict, choice: .keepServer, localSource: .queuedCiphertext)
            XCTFail("Expected resolve(.keepServer) to throw when noteContentService is not wired")
        } catch {
            // expected
        }

        XCTAssertEqual(engine.conflicts.count, 1, "An unresolved conflict must not be silently cleared")
    }

    func test_resolve_fork_withoutNoteContentServiceWired_throwsAndLeavesConflictUnresolved() async {
        let (engine, _, conflict) = await makeEngineWithActiveConflict()
        XCTAssertNil(engine.noteContentService)

        do {
            _ = try await engine.resolve(conflict, choice: .fork, localSource: .queuedCiphertext)
            XCTFail("Expected resolve(.fork) to throw when noteContentService is not wired")
        } catch {
            // expected
        }

        XCTAssertEqual(engine.conflicts.count, 1, "An unresolved conflict must not be silently cleared")
    }

    // MARK: - queueSnapshot

    func test_queueSnapshot_reflectsCurrentQueueStateAsEntriesDrain() async {
        let fake = FakeSyncExecutor()
        let engine = SyncEngine(persistence: makePersistence(), executor: fake,
                                 clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertTrue(engine.queueSnapshot.isEmpty)

        let entryA = makeRenameEntry(itemID: "a")
        let entryB = makeRenameEntry(itemID: "b")
        engine.enqueue(entryA)
        engine.enqueue(entryB)
        XCTAssertEqual(Set(engine.queueSnapshot.map(\.id)), Set([entryA.id, entryB.id]))

        fake.performResults[entryA.id] = .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))
        fake.performResults[entryB.id] = .failure(NotesDriveError.serverError(statusCode: 503))
        await engine.runSync()

        XCTAssertEqual(engine.queueSnapshot.map(\.id), [entryB.id])
        XCTAssertEqual(engine.queueSnapshot.first?.attemptCount, 1)
    }
}

// MARK: - Test Doubles

/// A `SyncOperationExecuting` test double with scriptable, per-entry results and a call log,
/// so `SyncEngineTests` can drive queue-draining, backoff, and conflict-detection logic without
/// touching the network.
private final class FakeSyncExecutor: SyncOperationExecuting {

    private(set) var performCalls: [SyncQueueEntry] = []
    private(set) var currentModifiedAtCalls: [String] = []

    /// Overrides `defaultPerformResult` for a specific entry, keyed by the entry's own `id`.
    var performResults: [UUID: Result<SyncOperationOutcome, Error>] = [:]
    var defaultPerformResult: Result<SyncOperationOutcome, Error> =
        .success(SyncOperationOutcome(createdItem: nil, updatedModifiedAt: nil))

    /// The server's "current modifiedAt" per itemID; absent keys resolve to nil (item not found).
    var currentModifiedAtResults: [String: Date] = [:]

    func perform(_ entry: SyncQueueEntry) async throws -> SyncOperationOutcome {
        performCalls.append(entry)
        let result = performResults[entry.id] ?? defaultPerformResult
        switch result {
        case .success(let outcome): return outcome
        case .failure(let error): throw error
        }
    }

    func currentModifiedAt(forItemID itemID: String) async throws -> Date? {
        currentModifiedAtCalls.append(itemID)
        return currentModifiedAtResults[itemID]
    }
}

/// A mutable clock box so `nextAttemptAt` scheduling can be advanced between `runSync()` calls
/// within a single test, while still being handed to `SyncEngine` as a plain `() -> Date` closure.
private final class MutableClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// A minimal placeholder `Error` for `.networkError(underlying:)`/`.decodingError(underlying:)`
/// cases where only the outer NotesDriveError case matters to the test, not the wrapped error.
private struct DummyError: Error {}
