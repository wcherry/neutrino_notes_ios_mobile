import Foundation
import NeutrinoCore

// MARK: - NoteTag

/// A Drive tag, as returned by `/api/v1/drive/tags`.
///
/// Tags belong to the user, not to a single note: a tag is created once and then attached to any
/// number of files. Note that a tag's *name* is stored on the server in the clear, exactly like a
/// file's name — note bodies stay end-to-end encrypted, but a tag is metadata the server can read.
struct NoteTag: Identifiable, Hashable, Codable {

    // MARK: - Properties

    let id: String
    var name: String
    let createdAt: Date
    /// Non-trashed files carrying this tag, as counted by the server on every tag response.
    /// Drive added this after Epic 12 shipped, so it is decoded leniently — an older server that
    /// omits the field yields 0 rather than failing the whole response.
    var fileCount: Int

    // MARK: - Init

    init(id: String, name: String, createdAt: Date, fileCount: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.fileCount = fileCount
    }

    // MARK: - Decoding

    /// The server sends camelCase keys and Drive's zone-less timestamps, the same shapes
    /// `NotesDriveService` decodes.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
    }

    // MARK: - Ordering

    /// Case-insensitive by name, with the id as a tiebreaker so the order is total and stable.
    static func byName(_ lhs: NoteTag, _ rhs: NoteTag) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order == .orderedSame { return lhs.id < rhs.id }
        return order == .orderedAscending
    }
}
