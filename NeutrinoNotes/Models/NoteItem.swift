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
    /// This is Drive's proprietary type for Markdown notes (the same value the `type=note`
    /// server-side filter matches on) — not the raw `text/markdown` media type. Confirmed
    /// against a live server response: an uploaded note round-trips as
    /// `mimeType: "application/x-neutrino-note"`.
    static let markdownMIME = "application/x-neutrino-note"

    // MARK: - Properties

    let id: String
    var name: String
    let type: ItemType
    var parentID: String?       // nil = root
    var size: Int64?            // bytes; nil for folders
    var modifiedAt: Date
    var isTrashed: Bool
    var mimeType: String?       // "application/x-neutrino-note" for files; nil for folders
    /// Epic 12: Drive's `isStarred` flag — the Favorites model, shared with the web app and
    /// carried by both files and folders. Defaulted so existing call sites are unaffected.
    var isStarred: Bool = false

    // MARK: - Computed

    /// Returns the appropriate SF Symbol name for this item.
    var iconName: String {
        type == .folder ? "folder.fill" : "doc.text.fill"
    }

    // MARK: - Visibility

    /// Folders are always shown (they're containers); files are shown only when Markdown.
    static func isVisibleInNotes(_ item: NoteItem) -> Bool {
        item.type == .folder || item.mimeType == markdownMIME
    }
}
