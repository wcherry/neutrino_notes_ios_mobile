import Foundation

// MARK: - NotesSection

/// The top-level sections available in the Notes browser.
enum NotesSection: String, CaseIterable, Identifiable {
    case myNotes = "My Notes"
    /// Epic 12: browses tags rather than items, so it has no `NoteItem`s of its own —
    /// `TagsView` owns its content (see `NotesDriveService.items(in:parentID:)`).
    case tags    = "Tags"
    case trash   = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Icon

    /// SF Symbol name representing this section in the picker.
    var iconName: String {
        switch self {
        case .myNotes: return "note.text"
        case .tags:    return "tag"
        case .trash:   return "trash"
        }
    }
}
