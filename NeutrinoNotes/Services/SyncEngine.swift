import Foundation
import os.log

// MARK: - SyncOperationOutcome

/// What a successfully-performed queued operation produced, so `SyncEngine` can reconcile
/// local state and watermarks without the executor needing to know about `NotesDriveService`
/// internals.
struct SyncOperationOutcome {
    var createdItem: NoteItem?
    var updatedModifiedAt: Date?
}

// MARK: - SyncOperationExecuting

/// Executes one queued operation against the real Drive/Note APIs. `SyncEngine`'s default
/// executor (`LiveSyncExecutor`, below) wraps `notesDriveService`/`noteContentService`;
/// `SyncEngineTests` inject a fake so queue-draining, backoff, and conflict logic are testable
/// without touching the network.
protocol SyncOperationExecuting {
    func perform(_ entry: SyncQueueEntry) async throws -> SyncOperationOutcome
    /// Lightweight current-modifiedAt lookup used to pre-check a saveNoteContent entry for
    /// conflicts before draining it. `nil` = item no longer exists server-side (or isn't known).
    func currentModifiedAt(forItemID itemID: String) async throws -> Date?
}

// MARK: - SyncEngineError

enum SyncEngineError: LocalizedError {
    case serviceUnavailable
    case executorUnavailable
    case malformedEntry

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:  return "This action requires network services that aren't currently available."
        case .executorUnavailable: return "Sync is not currently available."
        case .malformedEntry:      return "A queued sync operation was missing required data."
        }
    }
}

// MARK: - SyncEngine

/// The durable retry-queue engine: drains queued mutations with exponential backoff, detects
/// save conflicts before overwriting a note that changed server-side, and is the single code
/// path both the foreground triggers (launch, `scenePhase` active, periodic timer) and the
/// background `BGProcessingTask` handler call — see `runSync()`.
@MainActor
final class SyncEngine: ObservableObject {

    // MARK: - Shared

    /// The one deliberate per-instance-`@StateObject` exception in this codebase: BGTaskScheduler
    /// registration must happen before any `@StateObject` is guaranteed constructed, so
    /// `AppDelegate`'s background handler and `NeutrinoNotesApp`'s environment object need to
    /// share exactly one instance.
    static let shared = SyncEngine()

    // MARK: - Published State

    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncedAt: Date?
    @Published var lastError: String?
    @Published private(set) var conflicts: [SyncConflict] = []
    /// Retryable-kind entries that exhausted `SyncQueueEntry.maxAttempts` — `runSync()` no
    /// longer auto-retries these; only `retryNow(_:)` (the Offline tab's manual "Retry") does.
    @Published private(set) var failedEntries: [SyncQueueEntry] = []

    // MARK: - Dependencies

    weak var authService: AuthService?
    weak var notesDriveService: NotesDriveService?
    weak var noteContentService: NoteContentService?

    // MARK: - Private State

    private let persistence: SyncPersistence
    private let injectedExecutor: SyncOperationExecuting?
    private let clock: () -> Date

    private var queue: [SyncQueueEntry] = [] {
        didSet { pendingCount = queue.count }
    }
    private var watermarks: [String: Date] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes", category: "SyncEngine")

    // MARK: - Init

    init(
        persistence: SyncPersistence = .shared,
        executor: SyncOperationExecuting? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.injectedExecutor = executor
        self.clock = clock
        let loadedQueue = persistence.loadQueue()
        self.queue = loadedQueue
        self.watermarks = persistence.loadWatermarks()
        self.pendingCount = loadedQueue.count
    }

    // MARK: - Public API

    var queueSnapshot: [SyncQueueEntry] { queue }

    /// Persists `entry` immediately (before any network attempt) so it survives a relaunch even
    /// if the app is killed a moment later, then updates `pendingCount`.
    func enqueue(_ entry: SyncQueueEntry) {
        queue.append(entry)
        persistence.saveQueue(queue)
        logger.debug("enqueue: kind=\(entry.kind.rawValue, privacy: .public) itemID=\(entry.itemID ?? "-", privacy: .public)")
    }

    /// The one routine both the foreground triggers (launch, `scenePhase` active, periodic
    /// in-app timer) and the background `BGProcessingTask` handler call — there is exactly one
    /// sync code path, never duplicated logic between foreground/background.
    func runSync() async {
        guard !isSyncing else { return }
        guard let executor = resolvedExecutor() else {
            logger.debug("runSync: no executor available yet (services not wired) — skipping")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let now = clock()
        var remaining: [SyncQueueEntry] = []

        for var entry in queue {
            // Respect backoff — don't reattempt before nextAttemptAt. Only applies once a
            // failure has actually set nextAttemptAt against *this* engine's clock (attemptCount
            // > 0); a never-yet-attempted entry's default `nextAttemptAt = Date()` is just
            // object-creation-time noise (real wall-clock, not the injected clock) and must
            // never gate its first attempt.
            guard entry.attemptCount == 0 || entry.nextAttemptAt <= now else {
                remaining.append(entry)
                continue
            }

            if entry.kind == .saveNoteContent, let itemID = entry.itemID {
                do {
                    if let serverModifiedAt = try await executor.currentModifiedAt(forItemID: itemID),
                       let base = entry.baseModifiedAt,
                       serverModifiedAt > base {
                        raiseConflict(itemID: itemID, entry: entry, serverModifiedAt: serverModifiedAt, now: now)
                        remaining.append(entry)
                        continue
                    }
                } catch {
                    handleFailure(&entry, error: error, now: now, into: &remaining)
                    continue
                }
            }

            do {
                let outcome = try await executor.perform(entry)
                notesDriveService?.reconcile(entry: entry, outcome: outcome)
                if let itemID = entry.itemID, let modifiedAt = outcome.updatedModifiedAt {
                    watermarks[itemID] = modifiedAt
                }
                // Success — entry is dropped from the queue (not re-appended to `remaining`).
            } catch {
                handleFailure(&entry, error: error, now: now, into: &remaining)
            }
        }

        queue = remaining
        persistence.saveQueue(queue)
        persistence.saveWatermarks(watermarks)
        lastSyncedAt = now
    }

    /// Manual retry (the Offline tab's "Retry" button on a failed entry) — bypasses
    /// `nextAttemptAt`/`attemptCount` gating entirely, unlike the automatic `runSync()` path.
    func retryNow(_ entry: SyncQueueEntry) async {
        guard let executor = resolvedExecutor() else { return }
        var working = entry

        do {
            let outcome = try await executor.perform(working)
            notesDriveService?.reconcile(entry: working, outcome: outcome)
            if let itemID = working.itemID, let modifiedAt = outcome.updatedModifiedAt {
                watermarks[itemID] = modifiedAt
            }
            queue.removeAll { $0.id == working.id }
            failedEntries.removeAll { $0.id == working.id }
            persistence.saveQueue(queue)
            persistence.saveWatermarks(watermarks)
        } catch {
            failedEntries.removeAll { $0.id == working.id }
            queue.removeAll { $0.id == working.id }
            var rescheduled: [SyncQueueEntry] = []
            handleFailure(&working, error: error, now: clock(), into: &rescheduled)
            queue.append(contentsOf: rescheduled)
            persistence.saveQueue(queue)
        }
    }

    /// Resolves an active conflict per the user's explicit choice. Clears the matching entry
    /// from `conflicts` on success; on failure the conflict is left untouched (never silently
    /// cleared without actually resolving it).
    func resolve(
        _ conflict: SyncConflict, choice: ConflictChoice, localSource: ConflictLocalSource
    ) async throws -> ConflictResolutionOutcome {
        switch choice {
        case .keepMine:   return try await resolveKeepMine(conflict, localSource: localSource)
        case .keepServer: return try await resolveKeepServer(conflict)
        case .fork:       return try await resolveFork(conflict)
        }
    }

    /// Registers a conflict detected outside the queue-drain path — specifically, the live
    /// editor comparing its loaded `modifiedAt` against `NotesDriveService`'s freshly-synced
    /// value — so it surfaces in the same `conflicts` list and resolution flow as one detected
    /// during a queue drain.
    func reportConflict(itemID: String, itemName: String, parentID: String?, serverModifiedAt: Date, localModifiedAt: Date?) {
        guard !conflicts.contains(where: { $0.itemID == itemID }) else { return }
        conflicts.append(SyncConflict(
            id: UUID(), itemID: itemID, itemName: itemName, parentID: parentID,
            serverModifiedAt: serverModifiedAt, localModifiedAt: localModifiedAt, detectedAt: clock()
        ))
    }

    // MARK: - Conflict Resolution (private)

    private func resolveKeepMine(_ conflict: SyncConflict, localSource: ConflictLocalSource) async throws -> ConflictResolutionOutcome {
        switch localSource {
        case .queuedCiphertext:
            guard let executor = resolvedExecutor() else { throw SyncEngineError.executorUnavailable }
            guard let idx = queue.firstIndex(where: { $0.itemID == conflict.itemID && $0.kind == .saveNoteContent }) else {
                // Nothing queued to push — there's nothing to overwrite the server with, so just
                // clear the (now-moot) conflict.
                conflicts.removeAll { $0.id == conflict.id }
                return ConflictResolutionOutcome()
            }
            var entry = queue[idx]
            do {
                let outcome = try await executor.perform(entry)
                if let modifiedAt = outcome.updatedModifiedAt { watermarks[conflict.itemID] = modifiedAt }
                queue.remove(at: idx)
                persistence.saveQueue(queue)
                persistence.saveWatermarks(watermarks)
                conflicts.removeAll { $0.id == conflict.id }
                return ConflictResolutionOutcome()
            } catch {
                entry.lastError = error.localizedDescription
                queue[idx] = entry
                persistence.saveQueue(queue)
                throw error
            }

        case .editorText(let text, let dek):
            guard let noteContentService else { throw SyncEngineError.serviceUnavailable }
            guard let item = notesDriveService?.allItems.first(where: { $0.id == conflict.itemID }) else {
                throw SyncEngineError.serviceUnavailable
            }
            let updatedAt = try await noteContentService.saveContent(text, for: item, dek: dek)
            watermarks[conflict.itemID] = updatedAt
            notesDriveService?.noteContentWasSaved(itemID: conflict.itemID, size: Int64(text.utf8.count), modifiedAt: updatedAt)
            queue.removeAll { $0.itemID == conflict.itemID && $0.kind == .saveNoteContent }
            persistence.saveQueue(queue)
            persistence.saveWatermarks(watermarks)
            conflicts.removeAll { $0.id == conflict.id }
            return ConflictResolutionOutcome()
        }
    }

    private func resolveKeepServer(_ conflict: SyncConflict) async throws -> ConflictResolutionOutcome {
        guard let noteContentService else { throw SyncEngineError.serviceUnavailable }
        guard let item = notesDriveService?.allItems.first(where: { $0.id == conflict.itemID }) else {
            throw SyncEngineError.serviceUnavailable
        }
        let (text, _) = try await noteContentService.loadContent(for: item)
        watermarks[conflict.itemID] = conflict.serverModifiedAt
        // Drop the stale local queued entry so it won't overwrite the server on next drain.
        queue.removeAll { $0.itemID == conflict.itemID && $0.kind == .saveNoteContent }
        persistence.saveQueue(queue)
        persistence.saveWatermarks(watermarks)
        conflicts.removeAll { $0.id == conflict.id }
        return ConflictResolutionOutcome(updatedLocalText: text, forkedItem: nil)
    }

    private func resolveFork(_ conflict: SyncConflict) async throws -> ConflictResolutionOutcome {
        guard let noteContentService, let notesDriveService else { throw SyncEngineError.serviceUnavailable }
        guard let originalItem = notesDriveService.allItems.first(where: { $0.id == conflict.itemID }) else {
            throw SyncEngineError.serviceUnavailable
        }
        let (serverText, _) = try await noteContentService.loadContent(for: originalItem)
        let baseName = (originalItem.name as NSString).deletingPathExtension
        let forkName = "\(baseName.isEmpty ? originalItem.name : baseName) (conflict copy).md"

        var created = try await noteContentService.createNote(name: forkName, parentID: conflict.parentID)
        let (_, forkDEK) = try await noteContentService.loadContent(for: created)
        let updatedAt = try await noteContentService.saveContent(serverText, for: created, dek: forkDEK)
        created.modifiedAt = updatedAt
        created.size = Int64(serverText.utf8.count)
        notesDriveService.noteWasCreated(created)
        watermarks[created.id] = updatedAt

        // The original note keeps its local edits and proceeds to sync normally (same as
        // Keep Mine, just not forced right now) — clearing the conflict is enough to unblock it.
        conflicts.removeAll { $0.id == conflict.id }
        return ConflictResolutionOutcome(updatedLocalText: nil, forkedItem: created)
    }

    // MARK: - Private Helpers

    private func resolvedExecutor() -> SyncOperationExecuting? {
        if let injectedExecutor { return injectedExecutor }
        return LiveSyncExecutor(notesDriveService: notesDriveService, noteContentService: noteContentService)
    }

    private func handleFailure(_ entry: inout SyncQueueEntry, error: Error, now: Date, into remaining: inout [SyncQueueEntry]) {
        let kind = entry.kind.rawValue
        let itemID = entry.itemID ?? "-"
        logger.error("sync operation failed: kind=\(kind, privacy: .public) itemID=\(itemID, privacy: .public) error=\(error, privacy: .public)")
        guard SyncErrorClassifier.isRetryable(error) else {
            // Non-retryable: dropped entirely — not retried, not added to failedEntries.
            lastError = error.localizedDescription
            return
        }
        entry.attemptCount += 1
        entry.nextAttemptAt = now.addingTimeInterval(SyncQueueEntry.backoffInterval(forAttempt: entry.attemptCount))
        entry.lastError = error.localizedDescription
        if entry.attemptCount >= SyncQueueEntry.maxAttempts {
            failedEntries.append(entry)
        } else {
            remaining.append(entry)
        }
    }

    private func raiseConflict(itemID: String, entry: SyncQueueEntry, serverModifiedAt: Date, now: Date) {
        guard !conflicts.contains(where: { $0.itemID == itemID }) else { return }
        let cachedItem = notesDriveService?.allItems.first(where: { $0.id == itemID })
        conflicts.append(SyncConflict(
            id: UUID(),
            itemID: itemID,
            itemName: cachedItem?.name ?? entry.fileName ?? itemID,
            parentID: cachedItem?.parentID,
            serverModifiedAt: serverModifiedAt,
            localModifiedAt: entry.baseModifiedAt,
            detectedAt: now
        ))
        logger.debug("runSync: raised conflict for itemID=\(itemID, privacy: .public)")
    }
}

// MARK: - LiveSyncExecutor

/// The production `SyncOperationExecuting` — routes each queued entry to the real
/// `NotesDriveService` (metadata operations) or `NoteContentService` (`saveNoteContent`).
/// Holds its dependencies weakly, mirroring `SyncEngine`'s own weak references to them.
@MainActor
private final class LiveSyncExecutor: SyncOperationExecuting {
    private weak var notesDriveService: NotesDriveService?
    private weak var noteContentService: NoteContentService?

    init(notesDriveService: NotesDriveService?, noteContentService: NoteContentService?) {
        self.notesDriveService = notesDriveService
        self.noteContentService = noteContentService
    }

    func perform(_ entry: SyncQueueEntry) async throws -> SyncOperationOutcome {
        if entry.kind == .saveNoteContent {
            guard let noteContentService else { throw SyncEngineError.serviceUnavailable }
            return try await noteContentService.performQueuedSave(entry)
        }
        guard let notesDriveService else { throw SyncEngineError.serviceUnavailable }
        return try await notesDriveService.performRemote(entry)
    }

    func currentModifiedAt(forItemID itemID: String) async throws -> Date? {
        // No per-item metadata endpoint exists server-side (confirmed: Drive only exposes
        // full-listing endpoints, no changes-feed) — this relies on the cache NotesDriveService's
        // delta sync (loadSection) keeps fresh each runSync cycle. A documented, acceptable
        // approximation for this epic: it means "freshly-known" is as of the previous cycle's
        // delta sync, not a live per-item fetch.
        notesDriveService?.allItems.first(where: { $0.id == itemID })?.modifiedAt
    }
}
