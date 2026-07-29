import Foundation
import SwiftUI

// MARK: - MarkdownInlineRenderer

/// Converts a run of `MarkdownInline` values into a single `AttributedString`,
/// suitable for hosting in a SwiftUI `Text`. Pure function, no view state.
enum MarkdownInlineRenderer {

    static func attributedString(for inlines: [MarkdownInline], footnotes: [MarkdownFootnote]) -> AttributedString {
        renderChildren(inlines, intent: [], link: nil)
    }

    // MARK: - Recursive Rendering

    private static func render(_ inline: MarkdownInline, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        switch inline {
        case .text(let string):
            var attributed = AttributedString(string)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .emphasis(let children):
            return renderChildren(children, intent: intent.union(.emphasized), link: link)

        case .strong(let children):
            return renderChildren(children, intent: intent.union(.stronglyEmphasized), link: link)

        case .strikethrough(let children):
            return renderChildren(children, intent: intent.union(.strikethrough), link: link)

        case .code(let code):
            var attributed = AttributedString(code)
            attributed.font = Font.system(.body, design: .monospaced)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .link(let inlines, let destination):
            return renderChildren(inlines, intent: intent, link: URL(string: destination))

        case .image(let alt, _, _):
            // Mid-paragraph images fall back to their alt text (documented limitation);
            // a paragraph that is entirely a single image is handled as a block by MarkdownView.
            var attributed = AttributedString(alt)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .footnoteReference(let label, let index):
            // Visible marker shows the 1-based index; the link points back at the
            // nn-footnote scheme so MarkdownView can intercept the tap.
            var attributed = AttributedString("\(index)")
            apply(intent: intent, link: URL(string: "nn-footnote://\(label)"), to: &attributed)
            return attributed

        case .softBreak:
            return AttributedString(" ")

        case .lineBreak:
            return AttributedString("\n")
        }
    }

    private static func renderChildren(_ children: [MarkdownInline], intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        var result = AttributedString()
        for child in children {
            result += render(child, intent: intent, link: link)
        }
        return result
    }

    private static func apply(intent: InlinePresentationIntent, link: URL?, to attributed: inout AttributedString) {
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        if let link {
            attributed.link = link
        }
    }
}
