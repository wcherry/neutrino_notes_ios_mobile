import Foundation
import NeutrinoCore

// MARK: - NoteFileInfo

/// The metadata Drive returns for a single file from `GET /api/v1/drive/files/{id}/info`.
///
/// This is the only Drive endpoint that answers questions about one file *the caller can access*
/// rather than one file the caller owns, which makes it the right source for two things a shared
/// note needs:
///
/// - `yourRole` — what this account may do with the note, which is what decides whether the editor
///   is writable (see `NoteEditorView`).
/// - `updatedAt` — the server's current version, used for the offline queue's conflict check.
///   The folder listing that used to answer this belongs to the note's *owner*, so it 404s for a
///   note shared with the caller, silently disabling conflict detection for exactly the notes two
///   people might be editing at once.
struct NoteFileInfo: Decodable, Hashable {

    // MARK: - Properties

    let id: String
    let name: String
    let sizeBytes: Int64
    let folderID: String?
    let mimeType: String?
    let updatedAt: Date
    /// Non-nil when the file is in the Trash. `/info` still describes a trashed file, unlike the
    /// listings, which drop it.
    let deletedAt: Date?
    let yourRole: ShareRole

    // MARK: - Init

    init(id: String, name: String, sizeBytes: Int64, folderID: String?, mimeType: String?,
         updatedAt: Date, deletedAt: Date? = nil, yourRole: ShareRole) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.folderID = folderID
        self.mimeType = mimeType
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.yourRole = yourRole
    }

    // MARK: - Computed

    /// True when the file is still where the caller can reach it — the condition the sync engine
    /// means by "the server still has this note".
    var isLive: Bool { deletedAt == nil }

    // MARK: - Decoding

    /// Drive's zone-less timestamps, camelCase keys — the same shapes the file listings use.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, mimeType, updatedAt, deletedAt, yourRole
        case folderID = "folderId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        yourRole = ShareRole(serverValue: try container.decode(String.self, forKey: .yourRole))
    }
}
