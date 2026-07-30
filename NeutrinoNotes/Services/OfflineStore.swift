import Foundation
import Sodium
import os.log

// MARK: - OfflineStoreError

enum OfflineStoreError: LocalizedError {
    case notCached
    case hasPendingEdit
    case noEncryptionKey
    case decryptionFailed
    case ioFailure(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notCached:       return "That note isn't available offline."
        case .hasPendingEdit:  return "That note has unsynced changes. Sync it before removing the offline copy."
        case .noEncryptionKey: return "No encryption key found. Please import a key before using offline notes."
        case .decryptionFailed: return "Failed to decrypt the offline copy of the note."
        case .ioFailure(let err): return "Offline storage error: \(err.localizedDescription)"
        }
    }
}

// MARK: - OfflineStore

// The on-disk cache of notes that are available offline.
//
// Layout, rooted at Application Support/OfflineNotes (or an injected directory in tests):
//
//     index.json          the whole catalogue, [OfflineNote]
//     <id>.bin            server ciphertext of the cached base version
//     <id>.pending.bin    ciphertext of the local pending edit, same DEK
//
// The cache stores the server's ciphertext verbatim and re-encrypts local edits with the very
// same per-file DEK, so cache-at-rest security is identical to the wire protocol and reading
// anything back requires the Curve25519 key pair in the Keychain. All crypto and networking is
// delegated to NoteContentService — this type invents none of its own.
@MainActor
final class OfflineStore: ObservableObject {

    // MARK: - Published State

    /// The catalogue, sorted by name, case-insensitive.
    @Published private(set) var notes: [OfflineNote] = []

    // MARK: - Dependencies

    /// Set once at app launch — the store delegates all crypto and networking to it.
    weak var noteContentService: NoteContentService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "OfflineStore")

    /// Root of the cache. Injected in tests; defaults to Application Support/OfflineNotes.
    private let directory: URL

    private static let indexFileName = "index.json"

    /// Dates round-trip exactly with the default (`.deferredToDate`) strategy, which matters
    /// because `serverModifiedAt` values are compared for conflict detection.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Init

    /// - Parameter directory: `nil` uses Application Support/OfflineNotes. Tests pass a temp directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        prepareDirectory()
        loadIndex()
    }

    // MARK: - Queries

    func note(id: String) -> OfflineNote? {
        notes.first { $0.id == id }
    }

    func isAvailableOffline(_ itemID: String) -> Bool {
        note(id: itemID) != nil
    }

    var pendingCount: Int {
        notes.reduce(into: 0) { $0 += ($1.pendingEdit == nil ? 0 : 1) }
    }

    var conflictCount: Int {
        notes.reduce(into: 0) { $0 += ($1.conflict == nil ? 0 : 1) }
    }

    /// Total size of the cached ciphertext blobs actually present on disk.
    var totalBytesOnDisk: Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(into: Int64(0)) { total, name in
            guard name.hasSuffix(".bin") else { return }
            let path = directory.appendingPathComponent(name).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber
            total += size?.int64Value ?? 0
        }
    }

    // MARK: - Download / Remove

    /// Fetches the sealed DEK and the encrypted body for `item` and persists both, replacing any
    /// previously cached base version. A pending edit for the same note is preserved untouched —
    /// its `baseServerModifiedAt` still points at the version it was written against, so the sync
    /// engine will still detect the conflict.
    func download(_ item: NoteItem) async throws {
        guard let content = noteContentService else {
            logger.error("download: noteContentService not set")
            throw OfflineStoreError.noEncryptionKey
        }
        logger.debug("download: id=\(item.id, privacy: .public)")

        let ciphertext: Data
        let sealedDEK: String
        do {
            (ciphertext, sealedDEK) = try await content.downloadEncrypted(for: item)
        } catch {
            logger.error("download failed: id=\(item.id, privacy: .public) error=\(error, privacy: .public)")
            throw OfflineStoreError.ioFailure(underlying: error)
        }

        // Decrypt once, in memory only, both to verify the blob is readable with this device's
        // key pair before it is cached and to record the plaintext size for display.
        let dek = try unseal(sealedDEK, using: content)
        let plaintext = try decrypt(ciphertext, dek: dek, using: content)

        // Prefer the server's authoritative timestamp; fall back to the listing's if the
        // lookup is unavailable, since a slightly stale base date only makes conflict
        // detection more conservative.
        var serverModifiedAt = item.modifiedAt
        if let fresh = try? await content.fetchServerModifiedAt(for: item) {
            serverModifiedAt = fresh
        }

        try write(ciphertext, to: baseURL(for: item.id))

        var note = self.note(id: item.id) ?? OfflineNote(
            id: item.id, name: item.name, parentID: item.parentID, mimeType: item.mimeType,
            sealedDEK: sealedDEK, serverModifiedAt: serverModifiedAt, cachedAt: Date(),
            sizeBytes: Int64(plaintext.utf8.count), pendingEdit: nil, conflict: nil
        )
        note.name = item.name
        note.parentID = item.parentID
        note.mimeType = item.mimeType ?? note.mimeType
        note.sealedDEK = sealedDEK
        note.serverModifiedAt = serverModifiedAt
        note.cachedAt = Date()
        if note.pendingEdit == nil { note.sizeBytes = Int64(plaintext.utf8.count) }
        try upsert(note)
        logger.debug("download succeeded: id=\(item.id, privacy: .public) bytes=\(ciphertext.count)")
    }

    /// Removes a note from the cache. Refuses to discard unsynced work.
    func remove(id: String) throws {
        guard let note = note(id: id) else { throw OfflineStoreError.notCached }
        guard note.pendingEdit == nil else {
            logger.error("remove refused: id=\(id, privacy: .public) has a pending edit")
            throw OfflineStoreError.hasPendingEdit
        }
        deleteBlobs(for: id)
        notes.removeAll { $0.id == id }
        try saveIndex()
        logger.debug("remove: id=\(id, privacy: .public)")
    }

    /// Removes every cached note, skipping any that still has unsynced changes.
    func removeAll() throws {
        let removable = notes.filter { $0.pendingEdit == nil }
        for note in removable { deleteBlobs(for: note.id) }
        let removableIDs = Set(removable.map(\.id))
        notes.removeAll { removableIDs.contains($0.id) }
        try saveIndex()
        logger.debug("removeAll: removed \(removable.count), kept \(self.notes.count) with pending edits")
    }

    // MARK: - Plaintext Access

    /// Decrypts the note for editing. The pending edit wins over the cached base version.
    /// Returns the DEK alongside the text so the editing session can re-encrypt without
    /// unsealing again — the same contract as `NoteContentService.loadContent(for:)`.
    func readPlaintext(id: String) throws -> (text: String, dek: Bytes) {
        guard let note = note(id: id) else { throw OfflineStoreError.notCached }
        guard let content = noteContentService else { throw OfflineStoreError.noEncryptionKey }

        let dek = try unseal(note.sealedDEK, using: content)

        // Fall back to the base version if the pending blob went missing (interrupted write,
        // manual cache surgery): better a stale read than a hard failure.
        var url = baseURL(for: id)
        if note.pendingEdit != nil, FileManager.default.fileExists(atPath: pendingURL(for: id).path) {
            url = pendingURL(for: id)
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("readPlaintext: blob missing for id=\(id, privacy: .public)")
            throw OfflineStoreError.notCached
        }
        return (try decrypt(data, dek: dek, using: content), dek)
    }

    /// Encrypts `text` with the note's own DEK and stores it as the pending edit. Only the
    /// ciphertext ever reaches disk. An existing pending edit keeps its `baseServerModifiedAt`,
    /// so a chain of offline edits is still measured against the version they started from.
    func writePendingEdit(_ text: String, id: String, dek: Bytes) throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        guard let content = noteContentService else { throw OfflineStoreError.noEncryptionKey }

        let ciphertext: Data
        do {
            ciphertext = try content.encrypt(text: text, dek: dek,
                                             xcss: Self.sodium.secretStream.xchacha20poly1305)
        } catch {
            logger.error("writePendingEdit: encrypt failed id=\(id, privacy: .public) error=\(error, privacy: .public)")
            throw OfflineStoreError.decryptionFailed
        }
        try write(ciphertext, to: pendingURL(for: id))

        note.pendingEdit = PendingEdit(
            editedAt: Date(),
            baseServerModifiedAt: note.pendingEdit?.baseServerModifiedAt ?? note.serverModifiedAt,
            attemptCount: 0,
            lastError: nil,
            lastAttemptAt: nil
        )
        note.sizeBytes = Int64(text.utf8.count)
        try upsert(note)
        logger.debug("writePendingEdit: id=\(id, privacy: .public) (\(text.utf8.count) plaintext bytes)")
    }

    // MARK: - Sync-Engine Callbacks

    /// Replaces the cached base version with a newer server ciphertext. Pending edits and
    /// conflicts are left alone; the caller decides what happens to them.
    func acceptServerVersion(_ ciphertext: Data, id: String, serverModifiedAt: Date, sizeBytes: Int64) throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        try write(ciphertext, to: baseURL(for: id))
        note.serverModifiedAt = serverModifiedAt
        note.sizeBytes = sizeBytes
        note.cachedAt = Date()
        try upsert(note)
        logger.debug("acceptServerVersion: id=\(id, privacy: .public)")
    }

    /// Refreshes the cached base version from text this device just successfully uploaded,
    /// without going back to the network for bytes we already have. The ciphertext differs from
    /// the server's (a fresh secretstream header) but decrypts to exactly what the server now
    /// holds, under the same DEK.
    func cacheLocalVersion(_ text: String, id: String, dek: Bytes, serverModifiedAt: Date) throws {
        guard note(id: id) != nil else { throw OfflineStoreError.notCached }
        guard let content = noteContentService else { throw OfflineStoreError.noEncryptionKey }

        let ciphertext: Data
        do {
            ciphertext = try content.encrypt(text: text, dek: dek,
                                             xcss: Self.sodium.secretStream.xchacha20poly1305)
        } catch {
            logger.error("cacheLocalVersion: encrypt failed id=\(id, privacy: .public) error=\(error, privacy: .public)")
            throw OfflineStoreError.decryptionFailed
        }
        try acceptServerVersion(ciphertext, id: id,
                                serverModifiedAt: serverModifiedAt,
                                sizeBytes: Int64(text.utf8.count))
    }

    /// Called after a successful upload. The pending ciphertext is promoted to be the cached
    /// base version — it decrypts to exactly what the server now holds — and any conflict flag
    /// is cleared.
    func clearPendingEdit(id: String, serverModifiedAt: Date) throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        let pending = pendingURL(for: id)
        if FileManager.default.fileExists(atPath: pending.path) {
            do {
                let data = try Data(contentsOf: pending)
                try write(data, to: baseURL(for: id))
                try? FileManager.default.removeItem(at: pending)
            } catch {
                throw OfflineStoreError.ioFailure(underlying: error)
            }
        }
        note.pendingEdit = nil
        note.conflict = nil
        note.serverModifiedAt = serverModifiedAt
        note.cachedAt = Date()
        try upsert(note)
        logger.debug("clearPendingEdit: id=\(id, privacy: .public)")
    }

    /// Moves the note's base timestamp forward after a *metadata-only* server write — a rename or
    /// a star, both of which set `updated_at = now` without touching the note's content.
    ///
    /// Without this, SyncEngine sees the server ahead of the version a pending edit was written
    /// against and flags a conflict, asking the user to choose between two copies of their own
    /// text. The rebase is skipped when the cache already knows about a version at or beyond the
    /// one the metadata write was made against, so a genuine remote content edit still conflicts.
    ///
    /// Best-effort: the metadata write has already succeeded, and the worst outcome of a failure
    /// here is the spurious conflict this exists to avoid, which the user can still resolve.
    func rebasePendingEdit(id: String, previousModifiedAt: Date, serverModifiedAt: Date) {
        guard var note = note(id: id) else { return }
        guard serverModifiedAt > note.serverModifiedAt else { return }
        guard note.serverModifiedAt <= previousModifiedAt else {
            logger.debug("rebasePendingEdit skipped: id=\(id, privacy: .public) — cache already newer than the write's base")
            return
        }
        note.serverModifiedAt = serverModifiedAt
        if note.pendingEdit != nil {
            note.pendingEdit?.baseServerModifiedAt = serverModifiedAt
        }
        try? upsert(note)
        logger.debug("rebasePendingEdit: id=\(id, privacy: .public) -> \(serverModifiedAt.description, privacy: .public)")
    }

    /// Records a failed upload attempt, which pushes the note further down the backoff curve.
    func recordFailure(id: String, error: String) throws {
        guard var note = note(id: id), note.pendingEdit != nil else {
            throw OfflineStoreError.notCached
        }
        note.pendingEdit?.attemptCount += 1
        note.pendingEdit?.lastError = error
        note.pendingEdit?.lastAttemptAt = Date()
        try upsert(note)
        logger.error("recordFailure: id=\(id, privacy: .public) attempt=\(note.pendingEdit?.attemptCount ?? 0) error=\(error, privacy: .public)")
    }

    /// Flags the note as conflicted: the server has moved past the version the pending edit was
    /// written against, so uploading would clobber somebody else's work.
    func markConflict(id: String, serverModifiedAt: Date) throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        note.conflict = Conflict(detectedAt: Date(), serverModifiedAt: serverModifiedAt)
        try upsert(note)
        logger.error("markConflict: id=\(id, privacy: .public) serverModifiedAt=\(serverModifiedAt.description, privacy: .public)")
    }

    // MARK: - Conflict Resolution

    /// Keeps the local edit: rebases it onto the newer server version so the next drain uploads
    /// it (deliberately overwriting the remote change), resets the backoff, and clears the flag.
    func resolveKeepingLocal(id: String) throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        guard note.pendingEdit != nil else { throw OfflineStoreError.notCached }
        if let conflict = note.conflict, conflict.serverModifiedAt > note.serverModifiedAt {
            note.serverModifiedAt = conflict.serverModifiedAt
        }
        note.pendingEdit?.baseServerModifiedAt = note.conflict?.serverModifiedAt ?? note.serverModifiedAt
        note.pendingEdit?.attemptCount = 0
        note.pendingEdit?.lastError = nil
        note.pendingEdit?.lastAttemptAt = nil
        note.conflict = nil
        try upsert(note)
        logger.debug("resolveKeepingLocal: id=\(id, privacy: .public)")
    }

    /// Keeps the server's version: throws the local edit away and re-downloads.
    func resolveKeepingServer(id: String) async throws {
        guard var note = note(id: id) else { throw OfflineStoreError.notCached }
        try? FileManager.default.removeItem(at: pendingURL(for: id))
        note.pendingEdit = nil
        note.conflict = nil
        try upsert(note)
        logger.debug("resolveKeepingServer: id=\(id, privacy: .public) — re-downloading")
        try await download(note.asNoteItem)
    }

    // MARK: - Crypto Helpers

    private func unseal(_ sealedDEK: String, using content: NoteContentService) throws -> Bytes {
        do {
            return try content.unsealDEK(sealedDEK)
        } catch NoteContentError.noEncryptionKey {
            throw OfflineStoreError.noEncryptionKey
        } catch {
            throw OfflineStoreError.decryptionFailed
        }
    }

    private func decrypt(_ data: Data, dek: Bytes, using content: NoteContentService) throws -> String {
        do {
            return try content.decrypt(data: data, dek: dek)
        } catch {
            throw OfflineStoreError.decryptionFailed
        }
    }

    // MARK: - Paths

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OfflineNotes", isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }

    private func baseURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).bin")
    }

    private func pendingURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).pending.bin")
    }

    // MARK: - Disk

    /// Creates the cache directory with data protection on and iCloud backup off. Failures are
    /// logged rather than thrown so the app still launches with an empty catalogue.
    private func prepareDirectory() {
        var url = directory
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            logger.error("prepareDirectory failed at \(self.directory.path, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            logger.error("write failed: \(url.lastPathComponent, privacy: .public) \(error, privacy: .public)")
            throw OfflineStoreError.ioFailure(underlying: error)
        }
    }

    private func deleteBlobs(for id: String) {
        try? FileManager.default.removeItem(at: baseURL(for: id))
        try? FileManager.default.removeItem(at: pendingURL(for: id))
    }

    /// A corrupt, truncated, or absent index degrades to an empty catalogue rather than crashing.
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else {
            logger.debug("loadIndex: no index at \(self.indexURL.path, privacy: .public) — starting empty")
            return
        }
        do {
            notes = try Self.decoder.decode([OfflineNote].self, from: data).sorted(by: Self.byName)
            logger.debug("loadIndex: \(self.notes.count) cached note(s)")
        } catch {
            logger.error("loadIndex: index.json unreadable, starting empty: \(error, privacy: .public)")
            notes = []
        }
    }

    /// Rewritten atomically on every mutation so a crash mid-write cannot leave a half-index.
    private func saveIndex() throws {
        let data: Data
        do {
            data = try Self.encoder.encode(notes)
        } catch {
            throw OfflineStoreError.ioFailure(underlying: error)
        }
        try write(data, to: indexURL)
    }

    private func upsert(_ note: OfflineNote) throws {
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = note
        } else {
            notes.append(note)
        }
        notes.sort(by: Self.byName)
        try saveIndex()
    }

    private static func byName(_ lhs: OfflineNote, _ rhs: OfflineNote) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order == .orderedSame { return lhs.id < rhs.id }
        return order == .orderedAscending
    }
}
