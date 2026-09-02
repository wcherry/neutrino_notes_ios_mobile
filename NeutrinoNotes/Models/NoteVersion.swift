import Foundation
import NeutrinoCore

// MARK: - NoteVersion

/// One snapshot in a note's version history, as returned by Drive's
/// `GET /api/v1/drive/files/{id}/versions`.
///
/// Decoded straight from the API shape rather than through a private DTO, because the diff
/// and the history sheet both work in terms of this type and it is worth testing the decode
/// on its own (see `NoteVersionTests`).
struct NoteVersion: Identifiable, Hashable, Decodable {

    // MARK: - Properties

    let id: String
    let fileID: String
    /// 1-based, monotonically increasing per file. v1 is the snapshot taken at upload.
    let versionNumber: Int
    let sizeBytes: Int64
    /// Set only for versions saved explicitly with a name; nil for automatic snapshots.
    let label: String?
    let createdAt: Date
    /// True for explicitly saved versions, which the server never prunes automatically.
    let isNamed: Bool

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id
        case fileID = "fileId"
        case versionNumber
        case sizeBytes
        case label
        case createdAt
        case isNamed
    }

    // MARK: - Display

    /// "Version 3" or, when the version was saved with a name, "Draft sent to Ana (v3)".
    var displayTitle: String {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Version \(versionNumber)"
        }
        return "\(label) (v\(versionNumber))"
    }

    /// "Version 3" regardless of label — used where space is tight, e.g. the compare picker.
    var shortTitle: String { "v\(versionNumber)" }

    // MARK: - Shared decoder

    /// The versions endpoint returns `createdAt` as a zoned RFC 3339 timestamp, while the
    /// restore endpoint returns file metadata with Drive's zone-less shape. `DriveDate` reads
    /// both, so one decoder covers every response this feature touches.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()
}
