import Foundation

// MARK: - MarkdownSlashCommand

/// Recognises the `/` format command the user is typing.
///
/// A slash typed as the first character of a line opens the format menu, and whatever is typed
/// after it narrows the menu down — so `/h1` is three keystrokes to a heading. Anything that ends
/// the token ends the menu: a space, deleting the slash, or moving the caret off it.
///
/// Pure, and in UTF-16 offsets, for the same reason as [MarkdownChecklist]: the caller is a
/// `UITextView`.
enum MarkdownSlashCommand {

    /// The `/` command the caret is sitting at the end of.
    struct Token: Equatable {
        /// The whole command including the slash — the range a chosen format replaces.
        let range: NSRange
        /// What has been typed after the slash, which is what the menu filters on.
        let query: String
    }

    /// The command in progress at `caret`, or `nil` when the caret isn't at the end of one.
    static func token(in text: NSString, caret: Int) -> Token? {
        guard caret >= 0, caret <= text.length else { return nil }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                          for: NSRange(location: caret, length: 0))

        // Only what precedes the caret matters: the menu is about what is being typed, and a line
        // that already has text after the caret can still be given a heading.
        let range = NSRange(location: lineStart, length: caret - lineStart)
        let typed = text.substring(with: range)
        guard typed.hasPrefix("/") else { return nil }

        // A space ends the command — "/ " and "/note to self" are ordinary text, not a menu.
        let query = String(typed.dropFirst())
        guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        return Token(range: range, query: query)
    }
}
