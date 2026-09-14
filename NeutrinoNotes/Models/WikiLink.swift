import Foundation

// MARK: - WikiLink

/// Recognises the `[[Another Note]]` syntax that ties one note to another.
///
/// The same three clients have to agree on what a wiki link *is*, so this is a deliberate port of
/// `web/packages/markdown`'s `extractWikiLinks` (and, before it, the backend's `parse_wiki_links`):
/// `[[`, anything that is not a `]`, `]]`; the inner text trimmed; empty targets dropped. The unit
/// tests are ports of that package's tests for the same reason.
///
/// Pure, and in UTF-16 offsets, for the same reason as [MarkdownChecklist] and
/// [MarkdownSlashCommand]: the callers are `NSString` and `UITextView`.
enum WikiLink {

    // MARK: - Extension Handling

    /// The suffix this app puts on every note it creates (`CreateNoteSheet`), and the web app puts
    /// on none of the notes it creates.
    ///
    /// The server resolves a `[[title]]` by comparing it to `files.name` with nothing but a
    /// lowercase fold (`src/links/service.rs`), so `[[Meeting Notes]]` does not match a file called
    /// `Meeting Notes.md`. Every link written on a phone would silently resolve to nothing — and
    /// silently, because an unresolvable title is a normal condition by design, not an error. So
    /// both spellings travel on the wire ([requestTitles]) and both are indexed locally
    /// ([indexKey]).
    static let markdownExtension = ".md"

    /// A note's name as a wiki link would spell it: `Meeting Notes.md` -> `Meeting Notes`.
    static func displayTitle(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(markdownExtension), trimmed.count > markdownExtension.count
        else { return trimmed }
        return String(trimmed.dropLast(markdownExtension.count))
    }

    /// The form a title is matched on locally: trimmed, extension-less, case-folded.
    static func indexKey(for title: String) -> String {
        displayTitle(for: title).lowercased()
    }

    // MARK: - Relative Markdown Links

    /// The note a relative `[text](destination)` link names, or nil when the destination is not a
    /// reference to another note in this drive.
    ///
    /// `[Help](Help.md)` is the other way Markdown says "that note over there", and the one a
    /// writer arriving from any other Markdown editor reaches for. It has to be resolved here
    /// because nothing else can: a bare file name is not something `openURL` can be handed, so
    /// such a link renders as a link and then does nothing at all.
    ///
    /// Only the file name is kept, because Drive resolves *titles* and not paths — there is no
    /// notion of "the folder this note is in" to resolve `../` against. So `./notes/Help.md` and
    /// `[[Help]]` find the same note, and both find nothing if no note by that name is known.
    ///
    /// A destination with a scheme is somebody else's: `https:`, `mailto:`, `tel:`, and the
    /// `nn-wikilink:`/`nn-footnote:` schemes this app mints for links it has already handled.
    static func title(forRelativeLink url: URL) -> String? {
        guard url.scheme == nil else { return nil }
        // A fragment-only link (`#section`) is an anchor inside the note being read; it names no
        // file, and `lastPathComponent` is empty for it.
        let name = url.lastPathComponent
        let decoded = (name.removingPercentEncoding ?? name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "/", "." and ".." are what a path with no file name at the end reduces to.
        guard !decoded.isEmpty, !["/", ".", ".."].contains(decoded) else { return nil }
        return decoded
    }

    // MARK: - Match

    /// One `[[…]]` occurrence in a piece of text.
    struct Match: Equatable {
        /// The whole link including both pairs of brackets, in UTF-16 offsets — the range the
        /// renderer replaces and the editor highlights.
        let range: NSRange
        /// The trimmed target, e.g. `Meeting Notes`. Never empty.
        let title: String
    }

    private static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]]*)\]\]"#)

    /// Every link in `text`, in order. Empty targets (`[[]]`, `[[   ]]`) are skipped: they name no
    /// file and rendering them as a link would offer to open nothing.
    static func matches(in text: NSString) -> [Match] {
        regex.matches(in: text as String, options: [], range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                let title = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return Match(range: match.range, title: title)
            }
    }

    static func matches(in text: String) -> [Match] {
        matches(in: text as NSString)
    }

    // MARK: - Titles

    /// The distinct titles `text` links to, in first-appearance order.
    ///
    /// Deduplicated case-insensitively because the server resolves case-insensitively: sending
    /// `Meeting Notes` and `meeting notes` would be two requests for one edge.
    static func titles(in text: String) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for match in matches(in: text) where seen.insert(match.title.lowercased()).inserted {
            titles.append(match.title)
        }
        return titles
    }

    /// What `PATCH /api/v1/links/{id}` is sent: every title, plus its `.md` spelling.
    ///
    /// Extra titles cost nothing — the server silently drops the ones that resolve to nothing,
    /// which is the same thing it does with a genuine typo. This is what makes a link written on a
    /// phone resolve to a note created on the web, and vice versa.
    static func requestTitles(in text: String) -> [String] {
        var request: [String] = []
        var seen = Set<String>()
        for title in titles(in: text) {
            for spelling in [title, title + markdownExtension]
            where seen.insert(spelling.lowercased()).inserted {
                request.append(spelling)
            }
        }
        return request
    }

    // MARK: - Autocomplete Token

    /// The `[[` link the caret is currently inside.
    struct Token: Equatable {
        /// From the opening `[[` to the caret — the range a chosen note's title replaces.
        let range: NSRange
        /// What has been typed since the `[[`, which is what the menu filters on.
        let query: String
    }

    /// The link in progress at `caret`, or `nil` when the caret isn't inside one.
    ///
    /// Only the text between the nearest unclosed `[[` and the caret counts. A link that is already
    /// closed (`[[Done]]|`) is finished, and a `]` or a line break in between means the user has
    /// moved on — in both cases the menu closes rather than following them down the page.
    static func token(in text: NSString, caret: Int) -> Token? {
        guard caret >= 2, caret <= text.length else { return nil }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                          for: NSRange(location: caret, length: 0))

        // Searched as an `NSString` throughout: `String.distance` counts characters, and one
        // emoji ahead of the caret would put the replacement range on the wrong offset.
        let beforeCaret = NSRange(location: lineStart, length: caret - lineStart)
        let openRange = text.range(of: "[[", options: .backwards, range: beforeCaret)
        guard openRange.location != NSNotFound else { return nil }

        let queryStart = openRange.location + openRange.length
        let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        // `]` closes a link; a stray `[` means a nearer bracket the caret is not inside.
        guard !query.contains("]"), !query.contains("[") else { return nil }

        return Token(range: NSRange(location: openRange.location, length: caret - openRange.location),
                     query: query)
    }
}
