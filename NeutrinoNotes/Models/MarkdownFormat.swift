import Foundation

// MARK: - MarkdownFormat

/// A piece of Markdown the editor can write for the user, offered by the `/` menu.
///
/// Each format is a snippet plus where the caret should end up inside it — after the marker for a
/// block format (`# `), between the markers for a wrapping one (`**|**`) — so that picking a format
/// leaves the user typing their own text rather than hunting for the gap.
struct MarkdownFormat: Identifiable, Equatable {

    let id: String
    let title: String
    let systemImage: String
    /// The bare marker, shown alongside the name so the menu doubles as a Markdown cheat sheet.
    let marker: String
    /// Extra words the menu matches on, for the formats people don't look up by name ("h1", "todo").
    let keywords: [String]
    /// The text that replaces the `/` command.
    let snippet: String
    /// Where the caret lands inside `snippet`, in UTF-16 units.
    let caretOffset: Int

    // MARK: - The Menu

    /// Every format the `/` menu offers, in the order it offers them: the ones a note actually
    /// tends to need, commonest first.
    static let all: [MarkdownFormat] = [
        MarkdownFormat(id: "heading1", title: "Heading 1", systemImage: "number",
                       marker: "#", keywords: ["h1", "title"],
                       snippet: "# ", caretOffset: 2),
        MarkdownFormat(id: "heading2", title: "Heading 2", systemImage: "number",
                       marker: "##", keywords: ["h2", "subtitle"],
                       snippet: "## ", caretOffset: 3),
        MarkdownFormat(id: "heading3", title: "Heading 3", systemImage: "number",
                       marker: "###", keywords: ["h3"],
                       snippet: "### ", caretOffset: 4),
        MarkdownFormat(id: "bold", title: "Bold", systemImage: "bold",
                       marker: "**", keywords: ["strong"],
                       snippet: "****", caretOffset: 2),
        MarkdownFormat(id: "italic", title: "Italic", systemImage: "italic",
                       marker: "*", keywords: ["emphasis"],
                       snippet: "**", caretOffset: 1),
        MarkdownFormat(id: "strikethrough", title: "Strikethrough", systemImage: "strikethrough",
                       marker: "~~", keywords: ["strike"],
                       snippet: "~~~~", caretOffset: 2),
        MarkdownFormat(id: "code", title: "Code", systemImage: "curlybraces",
                       marker: "`", keywords: ["inline", "monospace"],
                       snippet: "``", caretOffset: 1),
        MarkdownFormat(id: "codeBlock", title: "Code Block", systemImage: "chevron.left.forwardslash.chevron.right",
                       marker: "```", keywords: ["fence", "snippet"],
                       snippet: "```\n\n```", caretOffset: 4),
        MarkdownFormat(id: "link", title: "Link", systemImage: "link",
                       marker: "[]()", keywords: ["url", "href"],
                       snippet: "[]()", caretOffset: 1),
        MarkdownFormat(id: "quote", title: "Quote", systemImage: "text.quote",
                       marker: ">", keywords: ["blockquote"],
                       snippet: "> ", caretOffset: 2),
        MarkdownFormat(id: "bulletList", title: "Bulleted List", systemImage: "list.bullet",
                       marker: "-", keywords: ["unordered", "bullet"],
                       snippet: "- ", caretOffset: 2),
        MarkdownFormat(id: "numberedList", title: "Numbered List", systemImage: "list.number",
                       marker: "1.", keywords: ["ordered", "number"],
                       snippet: "1. ", caretOffset: 3),
        MarkdownFormat(id: "checklist", title: "Checklist", systemImage: "checklist",
                       marker: "- [ ]", keywords: ["todo", "task", "checkbox", "list"],
                       snippet: "- [ ] ", caretOffset: 6),
        MarkdownFormat(id: "divider", title: "Divider", systemImage: "minus",
                       marker: "---", keywords: ["rule", "separator", "line"],
                       snippet: "---\n", caretOffset: 4)
    ]

    // MARK: - Matching

    /// The formats a typed query narrows to, in menu order. An empty query offers everything.
    ///
    /// Matching is by prefix, on any word of the name as well as on the format's keywords, so
    /// "list" finds both list formats and "todo" finds the checklist.
    static func matching(_ query: String) -> [MarkdownFormat] {
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.matches(query) }
    }

    private func matches(_ query: String) -> Bool {
        let candidates = title.lowercased().split(separator: " ").map(String.init) + keywords
        return candidates.contains { $0.hasPrefix(query) }
    }
}
