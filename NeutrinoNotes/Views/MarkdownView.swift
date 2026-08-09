import SwiftUI

// MARK: - Wiki Link Environment

private struct WikiLinkResolvedTitlesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    /// The `[[titles]]` in the document being rendered that point at a note this device can find,
    /// as `WikiLink.indexKey` spells them.
    ///
    /// Passed through the environment rather than as a parameter because every nested renderer
    /// needs it and none of them decide it — threading it through `MarkdownBlockView`,
    /// `MarkdownListView`, `MarkdownTableView` and back out again would be four signatures changed
    /// to carry one constant.
    var wikiLinkResolvedTitles: Set<String> {
        get { self[WikiLinkResolvedTitlesKey.self] }
        set { self[WikiLinkResolvedTitlesKey.self] = newValue }
    }
}

// MARK: - MarkdownView

/// Read-only, scrollable renderer for a Markdown string. Parses `text` with
/// `MarkdownParser` and renders the resulting `MarkdownDocumentModel` as native
/// SwiftUI views (headings, lists, task lists, tables, code blocks, block
/// quotes, thematic breaks, images, links, and footnotes).
struct MarkdownView: View {

    let text: String

    /// What this device knows about the notes a `[[wiki link]]` might name. Decides which links are
    /// drawn live and which are drawn broken; an empty index draws them all broken, which is the
    /// right answer for a preview or a screen with no listings loaded.
    var wikiLinkIndex = WikiLinkIndex()
    /// Files that link *to* this one, rendered as a "Linked from" section under the note. Empty
    /// hides the section entirely — an unlinked note shouldn't pay for a heading.
    var backlinks: [FileLink] = []
    /// Called with the raw title when a wiki link is tapped, resolved or not. Absent means wiki
    /// links render but do nothing, which is what a read-only preview wants.
    var onWikiLinkTap: ((String) -> Void)?
    var onBacklinkTap: ((FileLink) -> Void)?

    @Namespace private var footnoteNamespace
    @State private var footnoteScrollTarget: String?

    private var document: MarkdownDocumentModel {
        MarkdownParser.parse(text)
    }

    /// The index keys of the titles in this note that resolve to something. Computed once per body
    /// and handed down through the environment so every nested renderer agrees.
    private var resolvedTitles: Set<String> {
        guard FeatureFlags.noteLinks else { return [] }
        return Set(
            WikiLink.titles(in: text)
                .map(WikiLink.indexKey(for:))
                .filter { wikiLinkIndex.item(for: $0) != nil }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, footnotes: document.footnotes)
                    }

                    if !document.footnotes.isEmpty {
                        footnotesSection
                    }

                    if FeatureFlags.noteLinks && !backlinks.isEmpty {
                        backlinksSection
                    }
                }
                .padding()
            }
            .environment(\.wikiLinkResolvedTitles, resolvedTitles)
            .environment(\.openURL, OpenURLAction { url in
                if let title = MarkdownInlineRenderer.wikiLinkTitle(from: url) {
                    guard let onWikiLinkTap else { return .handled }
                    onWikiLinkTap(title)
                    return .handled
                }
                guard url.scheme == "nn-footnote" else {
                    return .systemAction
                }
                let label = url.host ?? url.absoluteString.replacingOccurrences(of: "nn-footnote://", with: "")
                withAnimation {
                    proxy.scrollTo("footnote-\(label)", anchor: .top)
                }
                return .handled
            })
        }
    }

    // MARK: - Backlinks

    /// "Linked from" — the other side of the link graph, and the only place it is visible.
    ///
    /// Read access is all the endpoint needs, so this appears on a note shared with this account
    /// too. Rows for other file types (a doc that links here) are shown rather than filtered: the
    /// graph is drive-wide, and hiding half of it would make a note look less connected than it is.
    private var backlinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)
            Text("Linked from")
                .font(.headline)
            ForEach(backlinks) { link in
                Button {
                    onBacklinkTap?(link)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: link.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(link.displayTitle)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onBacklinkTap == nil)
            }
        }
    }

    // MARK: - Footnotes Section

    private var footnotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)
            Text("Footnotes")
                .font(.headline)
            ForEach(document.footnotes) { footnote in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(footnote.index).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(MarkdownInlineRenderer.attributedString(for: footnote.content,
                                                                 footnotes: document.footnotes,
                                                                 resolvedTitles: resolvedTitles))
                        .font(.footnote)
                }
                .id("footnote-\(footnote.id)")
            }
        }
    }
}

// MARK: - MarkdownBlockView

/// Renders a single `MarkdownBlock`, recursing into nested blocks (lists, block quotes).
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let footnotes: [MarkdownFootnote]

    @Environment(\.wikiLinkResolvedTitles) private var resolvedTitles

    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            Text(MarkdownInlineRenderer.attributedString(for: inlines, footnotes: footnotes,
                                                         resolvedTitles: resolvedTitles))
                .font(headingFont(for: level))

        case .paragraph(let inlines):
            paragraphView(inlines)

        case .list(let list):
            MarkdownListView(list: list, footnotes: footnotes, nestingLevel: 0)

        case .table(let table):
            MarkdownTableView(table: table, footnotes: footnotes)

        case .codeBlock(let code, let language):
            MarkdownCodeBlockView(code: code, language: language)

        case .blockQuote(let blocks):
            MarkdownBlockQuoteView(blocks: blocks, footnotes: footnotes)

        case .thematicBreak:
            Divider()
        }
    }

    /// A paragraph consisting entirely of a single image renders as a real block-level
    /// image; anything else (including images mixed with other text) renders through
    /// the inline renderer, which falls back to the image's alt text.
    @ViewBuilder
    private func paragraphView(_ inlines: [MarkdownInline]) -> some View {
        if inlines.count == 1, case let .image(alt, source, _) = inlines[0] {
            MarkdownImageView(alt: alt, source: source)
        } else {
            Text(MarkdownInlineRenderer.attributedString(for: inlines, footnotes: footnotes,
                                                         resolvedTitles: resolvedTitles))
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        case 5: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - MarkdownListView

struct MarkdownListView: View {
    let list: MarkdownList
    let footnotes: [MarkdownFootnote]
    let nestingLevel: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                MarkdownListItemView(
                    item: item,
                    footnotes: footnotes,
                    marker: marker(for: offset),
                    nestingLevel: nestingLevel
                )
            }
        }
        .padding(.leading, CGFloat(nestingLevel) * 16)
    }

    private func marker(for offset: Int) -> String {
        guard list.isOrdered else { return "\u{2022}" }
        let start = list.startIndex ?? 1
        return "\(start + offset)."
    }
}

// MARK: - MarkdownListItemView

struct MarkdownListItemView: View {
    let item: MarkdownListItem
    let footnotes: [MarkdownFootnote]
    let marker: String
    let nestingLevel: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            checkboxOrMarker
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(item.content.enumerated()), id: \.offset) { _, block in
                    if case .list(let nestedList) = block {
                        MarkdownListView(list: nestedList, footnotes: footnotes, nestingLevel: nestingLevel + 1)
                    } else {
                        MarkdownBlockView(block: block, footnotes: footnotes)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var checkboxOrMarker: some View {
        if let checkbox = item.checkbox {
            // Read-only: task list checkboxes are not interactive in this epic.
            Image(systemName: checkbox ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(checkbox ? "Checked" : "Unchecked")
        } else {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
        }
    }
}

// MARK: - MarkdownTableView

struct MarkdownTableView: View {
    let table: MarkdownTable
    let footnotes: [MarkdownFootnote]

    @Environment(\.wikiLinkResolvedTitles) private var resolvedTitles

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        Text(MarkdownInlineRenderer.attributedString(for: cell, footnotes: footnotes,
                                                                     resolvedTitles: resolvedTitles))
                            .font(.subheadline.bold())
                            .gridColumnAlignment(alignment(for: index))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(MarkdownInlineRenderer.attributedString(for: cell, footnotes: footnotes,
                                                                         resolvedTitles: resolvedTitles))
                                .gridColumnAlignment(alignment(for: index))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func alignment(for columnIndex: Int) -> HorizontalAlignment {
        guard columnIndex < table.alignments.count else { return .leading }
        switch table.alignments[columnIndex] {
        case .none, .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - MarkdownCodeBlockView

struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - MarkdownBlockQuoteView

struct MarkdownBlockQuoteView: View {
    let blocks: [MarkdownBlock]
    let footnotes: [MarkdownFootnote]

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, footnotes: footnotes)
                }
            }
            .padding(.leading, 4)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - MarkdownImageView

struct MarkdownImageView: View {
    let alt: String
    let source: String

    var body: some View {
        if let url = URL(string: source) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    imageFailureView
                @unknown default:
                    imageFailureView
                }
            }
        } else {
            imageFailureView
        }
    }

    private var imageFailureView: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(.secondary)
            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Preview

#Preview {
    MarkdownView(text: """
    # Heading

    Some **bold**, *italic*, and `code` text with a [link](https://example.com).

    - [ ] Todo
    - [x] Done

    | A | B |
    | --- | ---: |
    | 1 | 2 |

    > A quote.

    ---

    Footnote reference[^1].

    [^1]: The footnote body.
    """)
}
