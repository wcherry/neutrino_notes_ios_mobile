import Foundation

// MARK: - DirectoryUser

/// A Neutrino account, as returned by `GET /api/v1/auth/users/lookup?email=` and
/// `GET /api/v1/auth/users/search?q=`. This is the whole of what the directory exposes about
/// somebody else — enough to grant them a permission, which requires all three fields.
struct DirectoryUser: Identifiable, Hashable, Decodable {

    // MARK: - Properties

    let id: String
    let email: String
    let name: String

    // MARK: - Init

    init(id: String, email: String, name: String) {
        self.id = id
        self.email = email
        self.name = name
    }

    // MARK: - Display

    var displayName: String {
        name.isEmpty ? email : name
    }

    /// Shown under the name; suppressed when the name already *is* the email address.
    var displayDetail: String? {
        name.isEmpty ? nil : email
    }
}
