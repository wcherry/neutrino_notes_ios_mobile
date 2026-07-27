import SwiftUI

// MARK: - NoteRowView

/// A list row representing a single NoteItem, showing its icon, name, size, and date.
struct NoteRowView: View {

    // MARK: - Parameters

    let item: NoteItem

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            iconView
            textStack
            Spacer()
            badgeIcons
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackgroundColor)
                .frame(width: 40, height: 40)
            Image(systemName: item.iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconForegroundColor)
        }
    }

    private var iconBackgroundColor: Color {
        item.type == .folder ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15)
    }

    private var iconForegroundColor: Color {
        item.type == .folder ? .blue : .orange
    }

    // MARK: - Text

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let size = item.size {
            parts.append(formattedSize(size))
        }
        parts.append(formattedDate(item.modifiedAt))
        return parts.joined(separator: " · ")
    }

    // MARK: - Badge Icons

    private var badgeIcons: some View {
        HStack(spacing: 6) {
            if item.isTrashed {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("In Trash")
            }
            if item.type == .folder {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var components = [item.name]
        if item.type == .folder {
            components.append("Folder")
        } else if let size = item.size {
            components.append(formattedSize(size))
        }
        components.append("Modified \(formattedDate(item.modifiedAt))")
        if item.isTrashed { components.append("In Trash") }
        return components.joined(separator: ", ")
    }

    // MARK: - Formatting Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    List {
        NoteRowView(item: NoteItem(
            id: "1",
            name: "Meeting Notes.md",
            type: .file,
            parentID: nil,
            size: 4096,
            modifiedAt: Date().addingTimeInterval(-3600),
            isTrashed: false,
            mimeType: NoteItem.markdownMIME
        ))
        NoteRowView(item: NoteItem(
            id: "2",
            name: "Journal",
            type: .folder,
            parentID: nil,
            size: nil,
            modifiedAt: Date().addingTimeInterval(-86400),
            isTrashed: false,
            mimeType: nil
        ))
    }
}
