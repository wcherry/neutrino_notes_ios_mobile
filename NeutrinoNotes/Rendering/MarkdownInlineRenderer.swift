import Foundation
import SwiftUI

// MARK: - MarkdownInlineRenderer

/// Converts a run of `MarkdownInline` values into a single `AttributedString`,
/// suitable for hosting in a SwiftUI `Text`. Pure function, no view state.
enum MarkdownInlineRenderer {

    /// The URL scheme a `[[wiki link]]` is rendered with, so `MarkdownView` can intercept the tap
    /// instead of letting the system try to open it. Parallel to `nn-footnote://`.
    static let wikiLinkScheme = "nn-wikilink"

    /// The link URL for a wiki-link title, percent-encoded so a title with spaces or punctuation
    /// survives the round trip.
    static func wikiLinkURL(for title: String) -> URL? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title
        return URL(string: "\(wikiLinkScheme)://\(encoded)")
    }

    /// The title inside a `nn-wikilink://` URL, or nil if that isn't what this is.
    static func wikiLinkTitle(from url: URL) -> String? {
        guard url.scheme == wikiLinkScheme else { return nil }
        let encoded = url.host ?? String(url.absoluteString.dropFirst("\(wikiLinkScheme)://".count))
        return encoded.removingPercentEncoding ?? encoded
    }

    /// `resolvedTitles` decides how each wiki link is drawn: a title in the set points at a note
    /// this device knows about and is drawn as a live link; anything else is drawn as a broken one.
    /// Both stay tappable — an unknown title is an invitation to create the note, and may also be a
    /// note in a folder this session simply hasn't listed.
    static func attributedString(for inlines: [MarkdownInline],
                                 footnotes: [MarkdownFootnote],
                                 resolvedTitles: Set<String> = []) -> AttributedString {
        renderChildren(inlines, intent: [], link: nil, resolvedTitles: resolvedTitles)
    }

    // MARK: - Recursive Rendering

    private static func render(_ inline: MarkdownInline,
                               intent: InlinePresentationIntent,
                               link: URL?,
                               resolvedTitles: Set<String>) -> AttributedString {
        switch inline {
        case .text(let string):
            var attributed = AttributedString(string)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .emphasis(let children):
            return renderChildren(children, intent: intent.union(.emphasized), link: link, resolvedTitles: resolvedTitles)

        case .strong(let children):
            return renderChildren(children, intent: intent.union(.stronglyEmphasized), link: link, resolvedTitles: resolvedTitles)

        case .strikethrough(let children):
            return renderChildren(children, intent: intent.union(.strikethrough), link: link, resolvedTitles: resolvedTitles)

        case .code(let code):
            var attributed = AttributedString(code)
            attributed.font = Font.system(.body, design: .monospaced)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .link(let inlines, let destination):
            return renderChildren(inlines, intent: intent, link: URL(string: destination), resolvedTitles: resolvedTitles)

        case .wikiLink(let title):
            // The brackets are dropped: the title is what the writer meant to read as a link, and
            // leaving `[[…]]` on screen would make the rendered note look like its own source.
            var attributed = AttributedString(WikiLink.displayTitle(for: title))
            let isResolved = resolvedTitles.contains(WikiLink.indexKey(for: title))
            apply(intent: intent, link: wikiLinkURL(for: title), to: &attributed)
            // A broken link stays legible but stops claiming to lead somewhere; `MarkdownView`
            // tints the live ones through the environment's accent colour.
            if !isResolved {
                attributed.foregroundColor = .secondary
                attributed.underlineStyle = .single
            }
            return attributed

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

    private static func renderChildren(_ children: [MarkdownInline],
                                       intent: InlinePresentationIntent,
                                       link: URL?,
                                       resolvedTitles: Set<String>) -> AttributedString {
        var result = AttributedString()
        for child in children {
            result += render(child, intent: intent, link: link, resolvedTitles: resolvedTitles)
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
