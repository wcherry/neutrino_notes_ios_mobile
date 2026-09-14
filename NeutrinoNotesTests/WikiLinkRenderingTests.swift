import XCTest
import SwiftUI
import NeutrinoCore
@testable import NeutrinoNotes

/// Tests for how a `[[wiki link]]` survives parsing and comes out the other side of the renderer.
final class WikiLinkRenderingTests: XCTestCase {

    // MARK: - Helpers

    private func inlines(of markdown: String) -> [MarkdownInline] {
        guard case let .paragraph(inlines)? = MarkdownParser.parse(markdown).blocks.first else {
            return []
        }
        return inlines
    }

    // MARK: - Parsing

    func test_parse_splitsAParagraphAroundAWikiLink() {
        XCTAssertEqual(inlines(of: "See [[Meeting Notes]] today."),
                       [.text("See "), .wikiLink(title: "Meeting Notes"), .text(" today.")])
    }

    func test_parse_handlesTwoLinksInOneParagraph() {
        XCTAssertEqual(inlines(of: "[[A]] and [[B]]"),
                       [.wikiLink(title: "A"), .text(" and "), .wikiLink(title: "B")])
    }

    func test_parse_linkInsideEmphasisIsStillALink() {
        XCTAssertEqual(inlines(of: "*see [[A]]*"),
                       [.emphasis([.text("see "), .wikiLink(title: "A")])])
    }

    func test_parse_linkInsideInlineCodeStaysLiteral() {
        // Inline code reaches the converter as `InlineCode`, which the splitter never sees — so
        // documentation that talks *about* the syntax doesn't turn into links.
        XCTAssertEqual(inlines(of: "Type `[[Title]]` to link."),
                       [.text("Type "), .code("[[Title]]"), .text(" to link.")])
    }

    func test_parse_linkInsideAFencedCodeBlockStaysLiteral() {
        let blocks = MarkdownParser.parse("```\n[[Title]]\n```").blocks
        XCTAssertEqual(blocks, [.codeBlock("[[Title]]\n", nil)])
    }

    func test_parse_emptyBracketsAreNotALink() {
        XCTAssertEqual(inlines(of: "[[]] stays"), [.text("[[]] stays")])
    }

    func test_parse_linkInAHeadingIsALink() {
        XCTAssertEqual(MarkdownParser.parse("# See [[A]]").blocks,
                       [.heading(level: 1, inlines: [.text("See "), .wikiLink(title: "A")])])
    }

    func test_parse_documentWithoutLinksIsUnchanged() {
        XCTAssertEqual(inlines(of: "Plain **bold** text."),
                       [.text("Plain "), .strong([.text("bold")]), .text(" text.")])
    }

    // MARK: - Rendering

    func test_render_dropsTheBracketsAndLinksToTheWikiLinkScheme() {
        let rendered = MarkdownInlineRenderer.attributedString(
            for: [.wikiLink(title: "Meeting Notes")], footnotes: [], resolvedTitles: ["meeting notes"]
        )
        XCTAssertEqual(String(rendered.characters), "Meeting Notes")
        XCTAssertEqual(rendered.runs.first?.link?.scheme, MarkdownInlineRenderer.wikiLinkScheme)
    }

    func test_render_stripsTheExtensionFromALinkTypedWithOne() {
        let rendered = MarkdownInlineRenderer.attributedString(
            for: [.wikiLink(title: "Meeting Notes.md")], footnotes: []
        )
        XCTAssertEqual(String(rendered.characters), "Meeting Notes")
    }

    func test_render_unresolvedLinkIsMarkedButStillTappable() {
        let rendered = MarkdownInlineRenderer.attributedString(
            for: [.wikiLink(title: "Nowhere")], footnotes: [], resolvedTitles: []
        )
        let run = rendered.runs.first
        XCTAssertNotNil(run?.link, "an unresolved link stays tappable — it is an offer to create it")
        XCTAssertEqual(run?.foregroundColor, .secondary)
        XCTAssertEqual(run?.underlineStyle, .single)
    }

    func test_render_resolvedLinkIsNotGreyedOut() {
        let rendered = MarkdownInlineRenderer.attributedString(
            for: [.wikiLink(title: "Meeting Notes")], footnotes: [], resolvedTitles: ["meeting notes"]
        )
        XCTAssertNil(rendered.runs.first?.foregroundColor)
    }

    // MARK: - URL Round Trip

    func test_wikiLinkURL_roundTripsATitleWithSpacesAndPunctuation() {
        let title = "Q3 Plan / Draft #2"
        let url = MarkdownInlineRenderer.wikiLinkURL(for: title)
        XCTAssertNotNil(url)
        XCTAssertEqual(MarkdownInlineRenderer.wikiLinkTitle(from: url!), title)
    }

    func test_wikiLinkTitle_ignoresOtherSchemes() {
        XCTAssertNil(MarkdownInlineRenderer.wikiLinkTitle(from: URL(string: "https://example.com")!))
        XCTAssertNil(MarkdownInlineRenderer.wikiLinkTitle(from: URL(string: "nn-footnote://1")!))
    }

    // MARK: - Relative Markdown Links

    private func renderedLink(_ destination: String) -> URL? {
        MarkdownInlineRenderer.attributedString(
            for: [.link(inlines: [.text("Help")], destination: destination)],
            footnotes: []
        ).runs.first?.link
    }

    /// The bug this guards: `URL(string: "Help.md")` is a perfectly good relative URL, so the link
    /// rendered blue and tappable and then `openURL` silently declined it — a live-looking link
    /// that opened nothing. It is an internal reference and has to leave the view as one.
    func test_relativeMarkdownLink_rendersAsAWikiLink() throws {
        let url = try XCTUnwrap(renderedLink("Help.md"))

        XCTAssertEqual(url.scheme, MarkdownInlineRenderer.wikiLinkScheme)
        XCTAssertEqual(MarkdownInlineRenderer.wikiLinkTitle(from: url), "Help.md")
    }

    func test_relativeMarkdownLink_withAPath_rendersAsAWikiLinkToTheFileName() throws {
        let url = try XCTUnwrap(renderedLink("./notes/Help.md"))

        XCTAssertEqual(MarkdownInlineRenderer.wikiLinkTitle(from: url), "Help.md")
    }

    func test_absoluteMarkdownLink_isLeftAlone() {
        XCTAssertEqual(renderedLink("https://example.com/Help.md"),
                       URL(string: "https://example.com/Help.md"))
        XCTAssertEqual(renderedLink("mailto:someone@example.com"),
                       URL(string: "mailto:someone@example.com"))
    }

    func test_anchorLink_isLeftAlone() {
        XCTAssertEqual(renderedLink("#section"), URL(string: "#section"))
    }

    func test_renderedMarkdownLink_preservesInternalDocumentDestination() {
        let destination = NeutrinoAppLink.url(kind: .doc, fileID: "doc-1")!
        let rendered = MarkdownInlineRenderer.attributedString(
            for: [.link(inlines: [.text("Project brief")], destination: destination.absoluteString)],
            footnotes: []
        )

        XCTAssertEqual(rendered.runs.first?.link, destination)
        XCTAssertEqual(NeutrinoAppLink.destination(from: rendered.runs.first!.link!)?.kind, .doc)
        XCTAssertEqual(NeutrinoAppLink.destination(from: rendered.runs.first!.link!)?.fileID, "doc-1")
    }
}
