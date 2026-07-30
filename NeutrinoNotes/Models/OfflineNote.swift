import Foundation

// MARK: - OfflineNote

/// A single note that has been downloaded for offline use.
///
/// The catalogue of these values is persisted as `index.json` inside the offline cache
/// directory; the note's body never appears here. The body lives next to the index as
/// `<id>.bin` (the server's ciphertext, byte-for-byte) and, when the user has edited the
/// note while offline, `<id>.pending.bin` (the local edit, re-encrypted with the same DEK).
/// Nothing in the cache is ever stored as plaintext.
struct OfflineNote: Codable, Identifiable, Hashable {

    // MARK: - Properties

    /// Drive file ID — also the base name of the note's blobs on disk.
    let id: String
    var name: String
    var parentID: String?
    var mimeType: String?
    /// base64url `crypto_box_seal` blob exactly as returned by `GET /files/{id}/key`.
    var sealedDEK: String
    /// `updatedAt` of the server version stored in `<id>.bin`.
    var serverModifiedAt: Date
    var cachedAt: Date
    /// Plaintext size, for display only.
    var sizeBytes: Int64
    var pendingEdit: PendingEdit?
    var conflict: Conflict?

    // MARK: - Computed

    /// Rebuilds a `NoteItem` so the cached note can be passed straight to `NoteContentService`.
    var asNoteItem: NoteItem {
        NoteItem(
            id: id,
            name: name,
            type: .file,
            parentID: parentID,
            size: sizeBytes,
            modifiedAt: serverModifiedAt,
            isTrashed: false,
            mimeType: mimeType ?? NoteItem.markdownMIME
        )
    }
}

// MARK: - PendingEdit

/// A local edit that has not yet reached the server.
struct PendingEdit: Codable, Hashable {
    var editedAt: Date
    /// The server version this edit was made against. If the server has moved past it by the
    /// time we try to upload, the edit is a conflict rather than a save.
    var baseServerModifiedAt: Date
    var attemptCount: Int
    var lastError: String?
    /// When the last upload attempt failed. The retry backoff is measured from here rather
    /// than from `editedAt`, so an edit that has been sitting in the queue for a while is
    /// still held back between attempts instead of retrying on every drain.
    var lastAttemptAt: Date?

    /// The earliest moment this edit should be retried.
    var nextAttemptAt: Date {
        (lastAttemptAt ?? editedAt).addingTimeInterval(SyncBackoff.delay(forAttempt: attemptCount))
    }
}

// MARK: - Conflict

/// Recorded when the server moved ahead of the version a pending edit was based on.
struct Conflict: Codable, Hashable {
    var detectedAt: Date
    /// The newer server version that caused the conflict.
    var serverModifiedAt: Date
}

// MARK: - SyncBackoff

/// Exponential backoff for the retry queue. Pure + testable: no clock, no I/O.
enum SyncBackoff {

    /// Longest a failing note is held back between attempts.
    static let maximumDelay: TimeInterval = 300

    /// 0 attempts -> 0s, then 5s, 15s, 45s, 135s, … capped at 300s.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // 5 * 3^(attempt - 1), computed in floating point so a large attemptCount cannot
        // overflow before the cap is applied.
        let raw = 5 * pow(3.0, Double(attempt - 1))
        return min(raw, maximumDelay)
    }
}
