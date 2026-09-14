import Foundation

// MARK: - NoteItem

/// Model for a single folder or Markdown file within the user's notes in Neutrino Drive.
struct NoteItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// The only file MIME type the Notes app browses — everything else lives in Drive but is
    /// out of scope for this app, per the roadmap: "browse only Markdown documents."
    ///
    /// A note *is* a Markdown document: the body is Markdown and the row carries the standard
    /// media type, which is the same value the `type=note` server-side filter matches on. Drive
    /// used to store a proprietary `application/x-neutrino-note` here, which is what let the web
    /// app keep note bodies in a private JSON format this app could not read.
    static let markdownMIME = "text/markdown"

    // MARK: - Properties

    let id: String
    var name: String
    let type: ItemType
    var parentID: String?       // nil = root
    var size: Int64?            // bytes; nil for folders
    var modifiedAt: Date
    var isTrashed: Bool
    var mimeType: String?       // "text/markdown" for files; nil for folders
    /// Epic 12: Drive's `isStarred` flag — the Favorites model, shared with the web app and
    /// carried by both files and folders. Defaulted so existing call sites are unaffected.
    var isStarred: Bool = false
    /// Epic 22: true for items reached through `GET /drive/shared-with-me`, i.e. owned by somebody
    /// else. Every other Drive listing this app calls is owner-scoped server-side, so anything not
    /// carrying this flag belongs to the signed-in account — which is what decides whether the
    /// share sheet is available (only owners may list or change permissions) and whether the editor
    /// has to ask the server what this account is allowed to do.
    var isShared: Bool = false

    // MARK: - Computed

    /// Returns the appropriate SF Symbol name for this item.
    var iconName: String {
        type == .folder ? "folder.fill" : "doc.text.fill"
    }

}
