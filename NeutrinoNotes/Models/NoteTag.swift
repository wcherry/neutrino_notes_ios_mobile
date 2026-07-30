import Foundation

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

    // MARK: - Decoding

    /// The server sends camelCase keys and Drive's zone-less timestamps, the same shapes
    /// `NotesDriveService` decodes.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()

    // MARK: - Ordering

    /// Case-insensitive by name, with the id as a tiebreaker so the order is total and stable.
    static func byName(_ lhs: NoteTag, _ rhs: NoteTag) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order == .orderedSame { return lhs.id < rhs.id }
        return order == .orderedAscending
    }
}
