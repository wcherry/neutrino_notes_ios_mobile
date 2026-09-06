import Foundation
import Combine
import Sodium
import os.log
import NeutrinoCore

// MARK: - NoteSyncing

/// The slice of `NoteContentService` the sync engine actually needs. Exists so the drain loop —
/// and in particular its conflict check — can be exercised without real HTTP.
@MainActor
protocol NoteSyncing: AnyObject {
    func fetchServerModifiedAt(for item: NoteItem) async throws -> Date?
    func saveContent(_ text: String, for item: NoteItem, dek: Bytes) async throws -> Date
}

extension NoteContentService: NoteSyncing {}

// MARK: - NoteLinkPublishing

/// The slice of `LinksService` the drain loop needs, so the queue's link updates can be observed
/// in a test without an HTTP stack behind them.
@MainActor
protocol NoteLinkPublishing: AnyObject {
    /// `force` is spelled out rather than defaulted: a default argument doesn't satisfy a protocol
    /// requirement, and the queue always wants the ordinary, deduplicated behaviour anyway.
    func updateLinksIgnoringFailure(fileID: String, in text: String, force: Bool) async
}

extension LinksService: NoteLinkPublishing {}

// MARK: - SyncEngine

// Drains the offline edit queue whenever the device has connectivity.
//
// The single rule that governs the whole epic: a queued edit is only uploaded if the server is
// still on the version the edit was written against. If the server has moved ahead, the note is
// flagged as a conflict and left for the user to resolve — a queued edit never silently clobbers
// a remote one.
@MainActor
final class SyncEngine: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case offline
        case syncing(remaining: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSyncedAt: Date?

    // MARK: - Dependencies

    private let store: OfflineStore
    private let monitor: NetworkMonitor
    private let content: any NoteSyncing
    /// Epic 20. Optional because the queue is older than the link graph and works without it.
    private weak var links: (any NoteLinkPublishing)?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "SyncEngine")

    /// At most one drain runs at a time; every entry point funnels through this task.
    private var inFlight: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(store: OfflineStore,
         monitor: NetworkMonitor,
         content: any NoteSyncing,
         links: (any NoteLinkPublishing)? = nil) {
        self.store = store
        self.monitor = monitor
        self.content = content
        self.links = links
    }

    /// Set once at app launch, after the services exist. Separate from `init` because the two are
    /// built in the same breath and neither can be the other's constructor argument.
    func attach(links: any NoteLinkPublishing) {
        self.links = links
    }

    // MARK: - Lifecycle

    /// Begins observing connectivity; drains the queue whenever the device comes back online.
    func start() {
        guard cancellables.isEmpty else { return }
        state = monitor.isOnline ? .idle : .offline
        monitor.$isOnline
            .removeDuplicates()
            .sink { isOnline in
                // `@Published` fires from the main actor, but hop explicitly so this stays
                // correct under stricter concurrency checking.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if isOnline {
                        self.logger.debug("connectivity restored — draining queue")
                        self.requestSync()
                    } else {
                        self.inFlight?.cancel()
                        self.state = .offline
                    }
                }
            }
            .store(in: &cancellables)
        if monitor.isOnline { requestSync() }
    }

    /// Fire-and-forget drain (safe to call from a SwiftUI action). A no-op while a drain is
    /// already running.
    func requestSync() {
        _ = drainTask()
    }

    /// Awaitable drain, for pull-to-refresh and tests. If a drain is already running this awaits
    /// that one rather than starting a second.
    func syncNow() async {
        await drainTask().value
    }

    // MARK: - Drain

    private func drainTask() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        // Created and stored without an intervening suspension point, so the body cannot start
        // before `inFlight` is set — the re-entrancy guard has no window.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            self.inFlight = nil
        }
        inFlight = task
        return task
    }

    /// Per note with a pending edit, oldest `editedAt` first:
    /// 1. skip while inside the backoff window,
    /// 2. skip anything already flagged as a conflict,
    /// 3. compare the server's current `updatedAt` against the edit's base version — newer means
    ///    conflict, not upload,
    /// 4. otherwise decrypt the pending edit, save it, and clear the queue entry,
    /// 5. on failure record it and carry on with the next note.
    private func drain() async {
        guard monitor.isOnline else {
            state = .offline
            return
        }

        let now = Date()
        let queue = store.notes
            .filter { note in
                guard let edit = note.pendingEdit else { return false }
                guard note.conflict == nil else { return false }
                return now >= edit.nextAttemptAt
            }
            .sorted { ($0.pendingEdit?.editedAt ?? .distantPast) < ($1.pendingEdit?.editedAt ?? .distantPast) }

        guard !queue.isEmpty else {
            state = .idle
            lastSyncedAt = Date()
            return
        }

        logger.debug("drain: \(queue.count) queued edit(s)")
        var remaining = queue.count
        state = .syncing(remaining: remaining)
        var lastFailure: String?

        for note in queue {
            if Task.isCancelled { break }
            // Re-read: an earlier iteration (or the editor) may have changed this note.
            guard let current = store.note(id: note.id),
                  let edit = current.pendingEdit,
                  current.conflict == nil else {
                remaining -= 1
                state = .syncing(remaining: remaining)
                continue
            }

            do {
                let item = current.asNoteItem
                let serverModifiedAt = try await content.fetchServerModifiedAt(for: item)
                if let serverModifiedAt, serverModifiedAt > edit.baseServerModifiedAt {
                    logger.error("drain: conflict on id=\(note.id, privacy: .public) — server moved to \(serverModifiedAt.description, privacy: .public), edit was based on \(edit.baseServerModifiedAt.description, privacy: .public)")
                    try store.markConflict(id: note.id, serverModifiedAt: serverModifiedAt)
                } else {
                    let (text, dek) = try store.readPlaintext(id: note.id)
                    let updatedAt = try await content.saveContent(text, for: item, dek: dek)
                    try store.clearPendingEdit(id: note.id, serverModifiedAt: updatedAt)
                    logger.debug("drain: uploaded id=\(note.id, privacy: .public)")
                    // Epic 20: the content the graph describes is only now on the server, so this
                    // is where an offline edit's `[[links]]` become real. The editor deliberately
                    // skips this for a queued save for exactly that reason. Never throws — a
                    // stale edge must not turn a successful upload into a sync failure.
                    if FeatureFlags.noteLinks {
                        await links?.updateLinksIgnoringFailure(fileID: note.id, in: text, force: false)
                    }
                }
            } catch {
                let message = error.localizedDescription
                lastFailure = message
                logger.error("drain: id=\(note.id, privacy: .public) failed: \(error, privacy: .public)")
                try? store.recordFailure(id: note.id, error: message)
            }

            remaining -= 1
            state = .syncing(remaining: remaining)
        }

        if !monitor.isOnline || Task.isCancelled {
            // Connectivity dropped mid-drain; whatever is left stays queued.
            state = monitor.isOnline ? .idle : .offline
        } else if let lastFailure {
            state = .failed(lastFailure)
        } else {
            state = .idle
            lastSyncedAt = Date()
        }
    }
}
