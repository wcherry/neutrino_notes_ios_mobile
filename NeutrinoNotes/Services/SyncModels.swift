import Foundation
import Sodium

// MARK: - SyncOperationKind

/// Every mutation `NotesDriveService`/`NoteContentService` can perform against Neutrino Drive,
/// stored on a queued `SyncQueueEntry` so a failed attempt can be retried later without any of
/// the original call site's in-memory context.
enum SyncOperationKind: String, Codable {
    case createFolder, renameFolder, renameFile, trashFile, trashFolder,
         permanentDeleteFile, permanentDeleteFolder, moveFile, moveFolder,
         restoreFile, restoreFolder, emptyTrash, saveNoteContent
}

// MARK: - SyncQueueEntry

/// A single durable retry-queue entry. Deliberately a flat `Codable` struct (not an
/// enum-with-payload) so persistence to disk (`SyncPersistence`) is trivial JSON — `kind`
/// disambiguates which of the fields below are meaningful for a given entry; the rest are
/// simply left `nil`. Constructed exclusively via the static factories below so call sites
/// (NotesDriveService/NoteContentService's failure `catch` blocks) can't accidentally
/// populate the wrong fields for a given kind.
struct SyncQueueEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: SyncOperationKind
    var itemID: String?              // target item; nil only for emptyTrash
    var placeholderID: String?       // createFolder: local optimistic ID to reconcile
    var newName: String?             // rename / createFolder's name
    var previousName: String?        // rename revert-on-permanent-failure
    var newParentID: String?         // move / createFolder's parent; nil is a valid "root"
    var previousParentID: String?    // move revert
    var itemSnapshot: NoteItem?      // trash/restore/permanentDelete revert
    var trashSnapshot: [NoteItem]?   // emptyTrash revert
    var encryptedContentBase64: String?  // saveNoteContent: ciphertext, already E2EE-encrypted
                                          // at enqueue time — safe to persist to disk as-is.
                                          // The DEK itself is never persisted.
    var fileName: String?
    var mimeType: String?
    var baseModifiedAt: Date?        // watermark this save was staged against — used for
                                      // conflict detection before retry
    var createdAt: Date = Date()
    var attemptCount: Int = 0
    var nextAttemptAt: Date = Date()
    var lastError: String?

    // MARK: - Backoff / Exhaustion

    static let maxAttempts = 8

    /// Exponential backoff capped at 15 minutes: min(2^attemptCount * 5s, 900s).
    static func backoffInterval(forAttempt attemptCount: Int) -> TimeInterval {
        min(pow(2, Double(attemptCount)) * 5, 900)
    }

    // MARK: - Factories

    static func createFolder(placeholderID: String, name: String, parentID: String?) -> SyncQueueEntry {
        SyncQueueEntry(kind: .createFolder, placeholderID: placeholderID, newName: name, newParentID: parentID)
    }

    static func renameFolder(itemID: String, newName: String, previousName: String) -> SyncQueueEntry {
        SyncQueueEntry(kind: .renameFolder, itemID: itemID, newName: newName, previousName: previousName)
    }

    static func renameFile(itemID: String, newName: String, previousName: String) -> SyncQueueEntry {
        SyncQueueEntry(kind: .renameFile, itemID: itemID, newName: newName, previousName: previousName)
    }

    static func trashFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .trashFile, itemID: itemID, itemSnapshot: snapshot)
    }

    static func trashFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .trashFolder, itemID: itemID, itemSnapshot: snapshot)
    }

    static func permanentDeleteFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .permanentDeleteFile, itemID: itemID, itemSnapshot: snapshot)
    }

    static func permanentDeleteFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .permanentDeleteFolder, itemID: itemID, itemSnapshot: snapshot)
    }

    static func moveFile(itemID: String, newParentID: String?, previousParentID: String?) -> SyncQueueEntry {
        SyncQueueEntry(kind: .moveFile, itemID: itemID, newParentID: newParentID, previousParentID: previousParentID)
    }

    static func moveFolder(itemID: String, newParentID: String?, previousParentID: String?) -> SyncQueueEntry {
        SyncQueueEntry(kind: .moveFolder, itemID: itemID, newParentID: newParentID, previousParentID: previousParentID)
    }

    static func restoreFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .restoreFile, itemID: itemID, itemSnapshot: snapshot)
    }

    static func restoreFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry {
        SyncQueueEntry(kind: .restoreFolder, itemID: itemID, itemSnapshot: snapshot)
    }

    static func emptyTrash(snapshot: [NoteItem]) -> SyncQueueEntry {
        SyncQueueEntry(kind: .emptyTrash, trashSnapshot: snapshot)
    }

    static func saveNoteContent(
        itemID: String, encryptedContentBase64: String, fileName: String,
        mimeType: String, baseModifiedAt: Date?
    ) -> SyncQueueEntry {
        SyncQueueEntry(
            kind: .saveNoteContent, itemID: itemID, encryptedContentBase64: encryptedContentBase64,
            fileName: fileName, mimeType: mimeType, baseModifiedAt: baseModifiedAt
        )
    }
}

// MARK: - SyncConflict

/// Raised when a note's server `modifiedAt` has advanced past this device's last known
/// watermark while this device still holds an unsynced local edit for it — detected either
/// while draining a queued `saveNoteContent` entry, or live in `NoteEditorView`. Not persisted:
/// resolving it needs either the live editor's plaintext or a queued entry's ciphertext, both
/// already-available in-memory inputs (no persisted local body cache exists yet — that's
/// Epic 9).
struct SyncConflict: Identifiable, Equatable {
    let id: UUID
    let itemID: String
    let itemName: String
    let parentID: String?
    let serverModifiedAt: Date
    let localModifiedAt: Date?
    let detectedAt: Date
}

// MARK: - Conflict Resolution

/// The three, and only three, ways a `SyncConflict` may be resolved — no auto-merge, no
/// last-write-wins.
enum ConflictChoice {
    case keepMine
    case keepServer
    case fork
}

/// Where `SyncEngine.resolve(_:choice:localSource:)` should read "my" local content from.
/// `.keepServer`/`.fork` don't need this (they only read from the server), so it's only
/// consulted for `.keepMine`.
enum ConflictLocalSource {
    /// The live editor has plaintext + the DEK in memory.
    case editorText(String, dek: Bytes)
    /// Resolve using whatever ciphertext is already sitting in the matching queued
    /// `saveNoteContent` entry (looked up by the conflict's `itemID`).
    case queuedCiphertext
}

/// What the caller (editor or Offline tab) should do after a conflict is resolved.
struct ConflictResolutionOutcome {
    /// Set on `.keepServer`/`.fork` — the caller should refresh its displayed text with this.
    var updatedLocalText: String?
    /// Set on `.fork` — the newly created forked note.
    var forkedItem: NoteItem?
}

// MARK: - SyncErrorClassifier

/// Classifies an error thrown by a Drive/Note API call as retryable (transient — network
/// blips, 5xx server errors) or not (4xx, decode failures, auth, crypto). Shared by
/// `NotesDriveService`/`NoteContentService` (deciding revert-vs-enqueue at the original mutation
/// call site) and `SyncEngine` (deciding backoff-and-retry vs. drop during queue drain), so the
/// two layers can never disagree about what's worth retrying.
enum SyncErrorClassifier {
    static func isRetryable(_ error: Error) -> Bool {
        if let driveError = error as? NotesDriveError {
            switch driveError {
            case .networkError: return true
            case .serverError(let code): return (500...599).contains(code)
            case .notAuthenticated, .decodingError: return false
            }
        }
        if let contentError = error as? NoteContentError {
            switch contentError {
            case .networkError: return true
            case .serverError(let code): return (500...599).contains(code)
            case .notAuthenticated, .decodingError, .noEncryptionKey, .encryptionFailed, .decryptionFailed:
                return false
            }
        }
        return false
    }
}
