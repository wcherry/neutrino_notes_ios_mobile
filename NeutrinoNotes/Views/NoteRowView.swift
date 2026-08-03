import SwiftUI

// MARK: - NoteRowView

/// A list row representing a single NoteItem, showing its icon, name, size, and date.
struct NoteRowView: View {

    // MARK: - OfflineBadge

    /// Epic 9: the offline-availability state to show for this row, if any. Kept as a plain
    /// value type (rather than an `OfflineStore` environment dependency) so this view stays
    /// decoupled from the offline service and every existing call site/preview keeps working
    /// unchanged.
    enum OfflineBadge {
        case downloading
        case available
        case unsyncedChanges
    }

    // MARK: - Parameters

    let item: NoteItem
    /// Defaults to `nil` (no badge) so existing call sites and previews are unaffected.
    var offlineBadge: OfflineBadge? = nil
    /// Epic 12: whether this item is pinned on *this device*. Passed in rather than read from
    /// `PinStore` so the row stays a plain value-driven view, as with `offlineBadge`.
    var isPinned: Bool = false
    /// Epic 22: folders shared *with* this account can't be opened — Drive's folder listings are
    /// owner-scoped — so their rows drop the chevron rather than promise a screen that 404s.
    var showsDisclosure: Bool = true

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
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if item.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if item.isShared {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shared with you")
            }
            offlineBadgeView
            if item.type == .folder && showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var offlineBadgeView: some View {
        switch offlineBadge {
        case .downloading:
            ProgressView()
                .controlSize(.mini)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)
                .accessibilityLabel("Available Offline")
        case .unsyncedChanges:
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Unsynced Changes")
        case nil:
            EmptyView()
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
        if isPinned { components.append("Pinned on this device") }
        if item.isStarred { components.append("Favorite") }
        if item.isShared { components.append("Shared with you") }
        switch offlineBadge {
        case .downloading: components.append("Downloading for offline use")
        case .available: components.append("Available Offline")
        case .unsyncedChanges: components.append("Has unsynced changes")
        case nil: break
        }
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
        NoteRowView(
            item: NoteItem(
                id: "3",
                name: "Downloaded Note.md",
                type: .file,
                parentID: nil,
                size: 2048,
                modifiedAt: Date().addingTimeInterval(-7200),
                isTrashed: false,
                mimeType: NoteItem.markdownMIME
            ),
            offlineBadge: .available
        )
        NoteRowView(
            item: NoteItem(
                id: "4",
                name: "Edited Offline.md",
                type: .file,
                parentID: nil,
                size: 1024,
                modifiedAt: Date().addingTimeInterval(-120),
                isTrashed: false,
                mimeType: NoteItem.markdownMIME
            ),
            offlineBadge: .unsyncedChanges
        )
        NoteRowView(
            item: NoteItem(
                id: "5",
                name: "Pinned Favorite.md",
                type: .file,
                parentID: nil,
                size: 3072,
                modifiedAt: Date().addingTimeInterval(-600),
                isTrashed: false,
                mimeType: NoteItem.markdownMIME,
                isStarred: true
            ),
            isPinned: true
        )
    }
}
