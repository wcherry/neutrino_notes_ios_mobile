import Foundation

// MARK: - MarkdownChecklist

/// The Return-key behaviour for Markdown task lists (`- [ ] buy milk`) in the note editor.
///
/// Two rules, which together are what a checklist in any Markdown editor does:
///
/// 1. Return at the end of a checklist item starts the next one — the new line arrives with the
///    same indentation and bullet, and an empty box, so a list can be typed without retyping
///    `- [ ] ` each time. Ordered checklists get the next number.
/// 2. Return on an item that was never filled in ends the list instead: the marker is taken back
///    off that line rather than laying down another empty box below it.
///
/// The logic is pure so it can be tested without a text view, and works in UTF-16 offsets because
/// its caller is a `UITextView`, whose selection and edit ranges are `NSRange`s.
enum MarkdownChecklist {

    // MARK: - Return Action

    /// What the editor should do in place of inserting the newline the user typed.
    enum ReturnAction: Equatable {
        /// Insert this text instead of the newline: a newline followed by the next item's marker.
        case continueList(String)
        /// Delete this range — the abandoned marker — and insert no newline, leaving the caret on
        /// the now-empty line.
        case endList(NSRange)
    }

    /// The checklist handling for a Return typed at `range` (the selection it would replace), or
    /// `nil` when the line isn't a checklist item and the text view should just insert the newline.
    static func returnAction(in text: NSString, replacing range: NSRange) -> ReturnAction? {
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }

        // The line the caret sits on, without its trailing newline.
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                          for: NSRange(location: range.location, length: 0))
        let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)) as NSString

        guard let marker = Marker(line: line) else { return nil }

        // Typing Return from inside the marker itself (say, between the brackets) is an edit to the
        // marker, not the end of an item — leave it alone.
        guard range.location - lineStart >= marker.length else { return nil }

        let content = line.substring(from: marker.length).trimmingCharacters(in: .whitespaces)
        if content.isEmpty && range.length == 0 {
            return .endList(NSRange(location: lineStart, length: contentsEnd - lineStart))
        }
        return .continueList("\n" + marker.nextItemPrefix)
    }

    // MARK: - Marker

    /// A checklist marker at the head of a line: `  1. [x] `, `- [ ] `, and so on.
    private struct Marker {
        /// The line's leading whitespace, carried across so nested items stay at their level.
        let indent: String
        /// The bullet character for an unordered item, `nil` for an ordered one.
        let bullet: String?
        /// The item's number and delimiter (`3`, `.`) for an ordered item.
        let number: Int?
        let delimiter: String?
        /// How much of the line the marker occupies, in UTF-16 units, up to the closing bracket.
        let length: Int

        /// A checklist item's marker: indentation, a bullet or number, and a checkbox. The trailing
        /// space is a lookahead so `length` stops at the bracket — a marker at the very end of the
        /// line, before the user has typed anything after it, still matches.
        private static let pattern = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))[ \t]+\[[ xX]\](?=[ \t]|$)"#
        )

        init?(line: NSString) {
            let range = NSRange(location: 0, length: line.length)
            guard let match = Self.pattern.firstMatch(in: line as String, range: range) else { return nil }

            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : line.substring(with: range)
            }

            indent = group(1) ?? ""
            bullet = group(2)
            number = group(3).flatMap(Int.init)
            delimiter = group(4)
            length = match.range.length
        }

        /// The marker the next item down the list should start with. Always an empty box: ticking
        /// one item off doesn't mean the next one is done too.
        var nextItemPrefix: String {
            if let bullet {
                return "\(indent)\(bullet) [ ] "
            }
            let next = (number ?? 0) + 1
            return "\(indent)\(next)\(delimiter ?? ".") [ ] "
        }
    }
}
