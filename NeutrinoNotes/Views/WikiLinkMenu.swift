import SwiftUI

// MARK: - WikiLinkMenu

/// The note picker a `[[` opens in the editor, narrowed by whatever is typed after the brackets.
///
/// Sized from a fixed row height for the same reason as [SlashCommandMenu]: the editor has to know
/// how tall the menu is before it can decide whether it fits below the caret.
struct WikiLinkMenu: View {

    let suggestions: [NoteItem]
    /// The text typed so far, offered as a note to create when it matches nothing that exists.
    /// Nil when creating isn't possible here — offline, or on a note this account can only read.
    let createTitle: String?
    let onSelect: (NoteItem) -> Void
    let onCreate: (String) -> Void

    // MARK: - Metrics

    static let width: CGFloat = 280
    private static let rowHeight: CGFloat = 44
    private static let maximumVisibleRows: CGFloat = 4.5

    static func height(forRowCount count: Int) -> CGFloat {
        min(CGFloat(count), maximumVisibleRows) * rowHeight
    }

    /// How many rows this menu will draw for a given query — the create row counts.
    static func rowCount(suggestions: [NoteItem], createTitle: String?) -> Int {
        suggestions.count + (createTitle == nil ? 0 : 1)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { note in
                    Button {
                        onSelect(note)
                    } label: {
                        row(icon: "note.text", title: WikiLink.displayTitle(for: note.name), trailing: nil)
                    }
                    .buttonStyle(.plain)

                    if note != suggestions.last || createTitle != nil {
                        Divider().padding(.leading, 44)
                    }
                }

                if let createTitle {
                    Button {
                        onCreate(createTitle)
                    } label: {
                        row(icon: "plus.circle", title: "Create \u{201C}\(createTitle)\u{201D}", trailing: "New")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: Self.width,
               height: Self.height(forRowCount: Self.rowCount(suggestions: suggestions, createTitle: createTitle)))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityLabel("Link to a note")
    }

    private func row(icon: String, title: String, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    WikiLinkMenu(
        suggestions: [
            NoteItem(id: "1", name: "Meeting Notes.md", type: .file, parentID: nil, size: 10,
                     modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME),
            NoteItem(id: "2", name: "Project Plan.md", type: .file, parentID: nil, size: 10,
                     modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME),
        ],
        createTitle: "Meet",
        onSelect: { _ in },
        onCreate: { _ in }
    )
    .padding()
}
