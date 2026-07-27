import Foundation

// MARK: - NotesSection

/// The top-level sections available in the Notes browser.
enum NotesSection: String, CaseIterable, Identifiable {
    case myNotes = "My Notes"
    case trash   = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Icon

    /// SF Symbol name representing this section in the picker.
    var iconName: String {
        switch self {
        case .myNotes: return "note.text"
        case .trash:   return "trash"
        }
    }
}
