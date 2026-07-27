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
