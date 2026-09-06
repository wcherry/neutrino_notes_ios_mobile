import Foundation
import NeutrinoCore

// MARK: - ShareRole

/// A user's role on a shared file or folder, as Drive's permissions API defines them.
///
/// Roles are inherited down the folder tree server-side (`get_effective_role` walks parents), so
/// the role that matters for a note is the one the server reports for that note, not the one on
/// the folder it happens to sit in.
enum ShareRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case owner
    case editor
    case commenter
    case viewer

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display

    var label: String {
        switch self {
        case .owner:     return "Owner"
        case .editor:    return "Editor"
        case .commenter: return "Commenter"
        case .viewer:    return "Viewer"
        }
    }

    /// What the role actually permits, in the terms a note user cares about.
    var summary: String {
        switch self {
        case .owner:     return "Can edit and manage sharing"
        case .editor:    return "Can edit this note"
        case .commenter: return "Can read this note"
        case .viewer:    return "Can read this note"
        }
    }

    var iconName: String {
        switch self {
        case .owner:     return "crown"
        case .editor:    return "pencil"
        case .commenter: return "text.bubble"
        case .viewer:    return "eye"
        }
    }

    // MARK: - Capability

    /// True when Drive's autosave endpoint will accept a write from this role — it requires
    /// `owner` or `editor` and rejects everything else.
    ///
    /// A commenter is deliberately grouped with a viewer here: this app has no comment UI (that is
    /// Epic 23), so a commenter can do exactly what a viewer can do.
    var canEdit: Bool {
        self == .owner || self == .editor
    }

    /// The roles a share sheet may hand out. `owner` is missing on purpose: the server rejects
    /// granting it directly and requires the separate transfer-ownership endpoint.
    static let grantable: [ShareRole] = [.editor, .commenter, .viewer]

    // MARK: - Decoding

    /// Roles arrive as plain strings. An unrecognised one is read as `viewer` — the least
    /// privileged answer — rather than failing the whole permission list, so a role added to Drive
    /// later degrades to "can read" instead of breaking the screen.
    init(serverValue: String) {
        self = ShareRole(rawValue: serverValue.lowercased()) ?? .viewer
    }

    // MARK: - Ordering

    /// Owner first, then by descending privilege, then alphabetically — the order the share sheet
    /// lists people in.
    var sortRank: Int {
        switch self {
        case .owner:     return 0
        case .editor:    return 1
        case .commenter: return 2
        case .viewer:    return 3
        }
    }
}

// MARK: - SharePermission

/// One person's access to one file or folder, as returned by
/// `GET /api/v1/drive/{files,folders}/{id}/permissions`.
///
/// Note the absence of `createdAt`: the server stringifies it with Rust's `NaiveDateTime::to_string()`,
/// which emits `"2026-07-30 14:25:36"` — a space rather than the `T` every other Drive timestamp
/// uses, and not a shape `DriveDate` parses. Nothing in the UI needs it, so it is not decoded.
struct SharePermission: Identifiable, Hashable, Codable {

    // MARK: - Properties

    let id: String
    let userID: String
    let userEmail: String
    let userName: String
    var role: ShareRole

    // MARK: - Init

    init(id: String, userID: String, userEmail: String, userName: String, role: ShareRole) {
        self.id = id
        self.userID = userID
        self.userEmail = userEmail
        self.userName = userName
        self.role = role
    }

    // MARK: - Display

    /// Guest permissions created by a share link carry an empty email and the name "Guest", and a
    /// permission granted through transfer-ownership carries neither, so neither field can be
    /// assumed to be present.
    var displayName: String {
        if !userName.isEmpty { return userName }
        if !userEmail.isEmpty { return userEmail }
        return "Unknown user"
    }

    /// The secondary line of a person's row — omitted when it would just repeat the title.
    var displayDetail: String? {
        guard !userEmail.isEmpty, userEmail != displayName else { return nil }
        return userEmail
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "userId"
        case userEmail
        case userName
        case role
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userID = try container.decode(String.self, forKey: .userID)
        userEmail = try container.decodeIfPresent(String.self, forKey: .userEmail) ?? ""
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
        role = ShareRole(serverValue: try container.decode(String.self, forKey: .role))
    }

    // MARK: - Ordering

    /// Owner first, then by privilege, then by name — stable via the id so the list never jitters.
    static func byRoleThenName(_ lhs: SharePermission, _ rhs: SharePermission) -> Bool {
        if lhs.role.sortRank != rhs.role.sortRank { return lhs.role.sortRank < rhs.role.sortRank }
        let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if order == .orderedSame { return lhs.id < rhs.id }
        return order == .orderedAscending
    }
}
