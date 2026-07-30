import Foundation

// MARK: - NoteItem

/// Model for a single folder or Markdown file within the user's notes in Neutrino Drive.
///
/// `Codable` conformance (additive, auto-synthesized — every stored property is already
/// Codable-compatible) was added for Epic 8 (Sync Engine): `SyncQueueEntry` persists
/// `NoteItem`/`[NoteItem]` snapshots to disk as the revert/restore payload for queued
/// trash/restore/permanentDelete/emptyTrash operations.
struct NoteItem: Identifiable, Hashable, Codable {

    // MARK: - ItemType

    enum ItemType: Codable {
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
