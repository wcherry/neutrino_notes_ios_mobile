import SwiftUI

// MARK: - SlashCommandMenu

/// The format menu a `/` opens in the editor: a short list of Markdown to insert, narrowed by
/// whatever is typed after the slash.
///
/// Sized from a fixed row height rather than from its content, because the editor has to know how
/// tall it is to decide whether it fits below the caret or has to go above it.
struct SlashCommandMenu: View {

    let formats: [MarkdownFormat]
    let onSelect: (MarkdownFormat) -> Void

    // MARK: - Metrics

    static let width: CGFloat = 260
    private static let rowHeight: CGFloat = 44
    /// Half a row is left showing when the list is longer than this, so it reads as scrollable.
    private static let maximumVisibleRows: CGFloat = 4.5

    static func height(forRowCount count: Int) -> CGFloat {
        min(CGFloat(count), maximumVisibleRows) * rowHeight
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(formats) { format in
                    Button {
                        onSelect(format)
                    } label: {
                        row(for: format)
                    }
                    .buttonStyle(.plain)

                    if format != formats.last {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .frame(width: Self.width, height: Self.height(forRowCount: formats.count))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityLabel("Formats")
    }

    private func row(for format: MarkdownFormat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: format.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(format.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(format.marker)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    SlashCommandMenu(formats: MarkdownFormat.all) { _ in }
        .padding()
}
