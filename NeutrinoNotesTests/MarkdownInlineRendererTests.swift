import XCTest
import SwiftUI
@testable import NeutrinoNotes

final class MarkdownInlineRendererTests: XCTestCase {

    // MARK: - Helpers

    private func plainText(_ attributedString: AttributedString) -> String {
        String(attributedString.characters)
    }

    // MARK: - Plain Text

    func test_attributedString_plainText_preservesTextContent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.text("Hello world")], footnotes: [])

        XCTAssertEqual(plainText(result), "Hello world")
        XCTAssertNil(result.runs.first?.inlinePresentationIntent)
    }

    // MARK: - Bold / Strong

    func test_attributedString_strongText_hasStronglyEmphasizedIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.strong([.text("bold")])], footnotes: [])

        XCTAssertEqual(plainText(result), "bold")
        XCTAssertEqual(result.runs.first?.inlinePresentationIntent, .stronglyEmphasized)
    }

    // MARK: - Italic / Emphasis

    func test_attributedString_emphasisText_hasEmphasizedIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.emphasis([.text("italic")])], footnotes: [])

        XCTAssertEqual(plainText(result), "italic")
        XCTAssertEqual(result.runs.first?.inlinePresentationIntent, .emphasized)
    }

    // MARK: - Strikethrough

    func test_attributedString_strikethroughText_hasStrikethroughIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.strikethrough([.text("gone")])], footnotes: [])

        XCTAssertEqual(plainText(result), "gone")
        XCTAssertEqual(result.runs.first?.inlinePresentationIntent, .strikethrough)
    }

    // MARK: - Inline Code

    func test_attributedString_inlineCode_usesMonospacedSystemFont() {
        let result = MarkdownInlineRenderer.attributedString(for: [.code("let x = 1")], footnotes: [])

        XCTAssertEqual(plainText(result), "let x = 1")
        XCTAssertEqual(result.runs.first?.font, Font.system(.body, design: .monospaced))
    }

    // MARK: - Links

    func test_attributedString_link_setsLinkAttributeToDestinationURL() {
        let result = MarkdownInlineRenderer.attributedString(
            for: [.link(inlines: [.text("Example")], destination: "https://example.com")],
            footnotes: []
        )

        XCTAssertEqual(plainText(result), "Example")
        XCTAssertEqual(result.runs.first?.link, URL(string: "https://example.com"))
    }

    func test_attributedString_linkWithFormattedText_preservesInnerEmphasis() {
        let result = MarkdownInlineRenderer.attributedString(
            for: [.link(inlines: [.strong([.text("Bold Link")])], destination: "https://example.com")],
            footnotes: []
        )

        XCTAssertEqual(plainText(result), "Bold Link")
        let run = result.runs.first
        XCTAssertEqual(run?.link, URL(string: "https://example.com"))
        XCTAssertEqual(run?.inlinePresentationIntent, .stronglyEmphasized)
    }

    // MARK: - Footnote References

    func test_attributedString_footnoteReference_linksToFootnoteSchemeAndShowsIndex() {
        let footnotes = [MarkdownFootnote(id: "1", index: 1, content: [.text("The footnote body.")])]

        let result = MarkdownInlineRenderer.attributedString(
            for: [.footnoteReference(label: "1", index: 1)],
            footnotes: footnotes
        )

        // The visible marker must contain the 1-based index so the reader can see
        // which footnote is being referenced (e.g. rendered as superscript "1").
        XCTAssertTrue(plainText(result).contains("1"))
        XCTAssertEqual(result.runs.first?.link, URL(string: "nn-footnote://1"))
    }

    func test_attributedString_footnoteReference_withWordLabel_linksToLabelledScheme() {
        let footnotes = [MarkdownFootnote(id: "note", index: 1, content: [.text("Explanation.")])]

        let result = MarkdownInlineRenderer.attributedString(
            for: [.footnoteReference(label: "note", index: 1)],
            footnotes: footnotes
        )

        XCTAssertTrue(plainText(result).contains("1"))
        XCTAssertEqual(result.runs.first?.link, URL(string: "nn-footnote://note"))
    }

    func test_attributedString_secondFootnoteReference_showsItsOwnIndexNotTheFirsts() {
        let footnotes = [
            MarkdownFootnote(id: "a", index: 1, content: [.text("A.")]),
            MarkdownFootnote(id: "b", index: 2, content: [.text("B.")]),
        ]

        let result = MarkdownInlineRenderer.attributedString(
            for: [.footnoteReference(label: "b", index: 2)],
            footnotes: footnotes
        )

        XCTAssertTrue(plainText(result).contains("2"))
        XCTAssertEqual(result.runs.first?.link, URL(string: "nn-footnote://b"))
    }

    // MARK: - Mixed Runs

    func test_attributedString_mixedInlines_preservesOrderAndPerRunAttributes() {
        let result = MarkdownInlineRenderer.attributedString(
            for: [
                .strong([.text("bold")]),
                .text(" and "),
                .emphasis([.text("italic")]),
            ],
            footnotes: []
        )

        XCTAssertEqual(plainText(result), "bold and italic")

        let runs = Array(result.runs)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNil(runs[1].inlinePresentationIntent)
        XCTAssertEqual(runs[2].inlinePresentationIntent, .emphasized)
    }

    func test_attributedString_nestedEmphasisInsideStrong_combinesIntents() {
        let result = MarkdownInlineRenderer.attributedString(
            for: [.strong([.emphasis([.text("both")])])],
            footnotes: []
        )

        XCTAssertEqual(plainText(result), "both")
        XCTAssertEqual(result.runs.first?.inlinePresentationIntent, [.stronglyEmphasized, .emphasized])
    }

    func test_attributedString_emptyInlineArray_producesEmptyAttributedString() {
        let result = MarkdownInlineRenderer.attributedString(for: [], footnotes: [])

        XCTAssertEqual(plainText(result), "")
    }
}
