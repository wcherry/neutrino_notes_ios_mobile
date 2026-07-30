import XCTest
@testable import NeutrinoNotes

final class MarkdownParserTests: XCTestCase {

    // MARK: - Sanity / Happy Path

    func test_parse_plainParagraph_returnsSingleTextInline() {
        let document = MarkdownParser.parse("Hello world")

        XCTAssertEqual(document.blocks, [.paragraph([.text("Hello world")])])
        XCTAssertEqual(document.footnotes, [])
    }

    // MARK: - Empty Input

    func test_parse_emptyString_returnsEmptyDocument() {
        let document = MarkdownParser.parse("")

        XCTAssertEqual(document, MarkdownDocumentModel(blocks: [], footnotes: []))
    }

    // MARK: - Headings

    func test_parse_headingsH1ThroughH6_produceCorrectLevelsAndText() {
        let source = """
        # H1

        ## H2

        ### H3

        #### H4

        ##### H5

        ###### H6
        """

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .heading(level: 1, inlines: [.text("H1")]),
            .heading(level: 2, inlines: [.text("H2")]),
            .heading(level: 3, inlines: [.text("H3")]),
            .heading(level: 4, inlines: [.text("H4")]),
            .heading(level: 5, inlines: [.text("H5")]),
            .heading(level: 6, inlines: [.text("H6")]),
        ])
    }

    // MARK: - Lists

    func test_parse_unorderedListWithDashMarker_producesUnorderedList() {
        let source = """
        - one
        - two
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownList(
            isOrdered: false,
            startIndex: nil,
            items: [
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("one")])]),
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("two")])]),
            ]
        )
        XCTAssertEqual(document.blocks, [.list(expected)])
    }

    func test_parse_unorderedListWithAsteriskMarker_producesUnorderedList() {
        let source = """
        * one
        * two
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownList(
            isOrdered: false,
            startIndex: nil,
            items: [
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("one")])]),
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("two")])]),
            ]
        )
        XCTAssertEqual(document.blocks, [.list(expected)])
    }

    func test_parse_orderedListStartingAtOne_hasStartIndexOne() {
        let source = """
        1. one
        2. two
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownList(
            isOrdered: true,
            startIndex: 1,
            items: [
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("one")])]),
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("two")])]),
            ]
        )
        XCTAssertEqual(document.blocks, [.list(expected)])
    }

    func test_parse_orderedListStartingAtThree_preservesStartIndex() {
        let source = """
        3. three
        4. four
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownList(
            isOrdered: true,
            startIndex: 3,
            items: [
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("three")])]),
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("four")])]),
            ]
        )
        XCTAssertEqual(document.blocks, [.list(expected)])
    }

    func test_parse_nestedUnorderedList_producesNestedListInItemContent() {
        let source = """
        - Parent
          - Child
        """

        let document = MarkdownParser.parse(source)

        let childList = MarkdownList(
            isOrdered: false,
            startIndex: nil,
            items: [MarkdownListItem(checkbox: nil, content: [.paragraph([.text("Child")])])]
        )
        let parentList = MarkdownList(
            isOrdered: false,
            startIndex: nil,
            items: [
                MarkdownListItem(
                    checkbox: nil,
                    content: [.paragraph([.text("Parent")]), .list(childList)]
                )
            ]
        )
        XCTAssertEqual(document.blocks, [.list(parentList)])
    }

    // MARK: - Task List Items

    func test_parse_taskListItems_mapCheckboxStateCorrectly() {
        let source = """
        - [ ] todo
        - [x] done
        - plain item
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownList(
            isOrdered: false,
            startIndex: nil,
            items: [
                MarkdownListItem(checkbox: false, content: [.paragraph([.text("todo")])]),
                MarkdownListItem(checkbox: true, content: [.paragraph([.text("done")])]),
                MarkdownListItem(checkbox: nil, content: [.paragraph([.text("plain item")])]),
            ]
        )
        XCTAssertEqual(document.blocks, [.list(expected)])
    }

    // MARK: - Tables

    func test_parse_gfmTable_mapsAlignmentsHeaderAndRows() {
        let source = """
        | Header 1 | Header 2 | Header 3 | Header 4 |
        | --- | :--- | :---: | ---: |
        | a | b | c | d |
        """

        let document = MarkdownParser.parse(source)

        let expected = MarkdownTable(
            alignments: [.none, .leading, .center, .trailing],
            header: [
                [.text("Header 1")],
                [.text("Header 2")],
                [.text("Header 3")],
                [.text("Header 4")],
            ],
            rows: [
                [[.text("a")], [.text("b")], [.text("c")], [.text("d")]],
            ]
        )
        XCTAssertEqual(document.blocks, [.table(expected)])
    }

    func test_parse_gfmTable_withMultipleRows_preservesRowOrder() {
        let source = """
        | Name | Score |
        | --- | ---: |
        | Alice | 10 |
        | Bob | 20 |
        """

        let document = MarkdownParser.parse(source)

        guard case let .table(table)? = document.blocks.first, document.blocks.count == 1 else {
            XCTFail("Expected a single table block")
            return
        }

        XCTAssertEqual(table.rows, [
            [[.text("Alice")], [.text("10")]],
            [[.text("Bob")], [.text("20")]],
        ])
    }

    // MARK: - Code Blocks

    func test_parse_fencedCodeBlockWithLanguage_preservesLanguageAndVerbatimContent() {
        let source = """
        ```swift
        func foo() {
            return 1
        }
        ```
        """

        let document = MarkdownParser.parse(source)

        guard case let .codeBlock(code, language)? = document.blocks.first, document.blocks.count == 1 else {
            XCTFail("Expected a single code block")
            return
        }

        XCTAssertEqual(language, "swift")
        // Trim only the outer trailing newline that fenced code blocks commonly carry;
        // internal indentation must be preserved verbatim.
        XCTAssertEqual(code.trimmingCharacters(in: .whitespacesAndNewlines), "func foo() {\n    return 1\n}")
    }

    func test_parse_fencedCodeBlockWithoutInfoString_hasNilLanguage() {
        let source = """
        ```
        plain code
        ```
        """

        let document = MarkdownParser.parse(source)

        guard case let .codeBlock(code, language)? = document.blocks.first, document.blocks.count == 1 else {
            XCTFail("Expected a single code block")
            return
        }

        XCTAssertNil(language)
        XCTAssertEqual(code.trimmingCharacters(in: .whitespacesAndNewlines), "plain code")
    }

    // MARK: - Block Quotes

    func test_parse_blockQuote_wrapsParagraphInBlockQuote() {
        let document = MarkdownParser.parse("> Outer quote")

        XCTAssertEqual(document.blocks, [.blockQuote([.paragraph([.text("Outer quote")])])])
    }

    func test_parse_nestedBlockQuote_producesNestedBlockQuoteBlock() {
        let source = """
        > Outer
        > > Inner
        """

        let document = MarkdownParser.parse(source)

        let expected: MarkdownBlock = .blockQuote([
            .paragraph([.text("Outer")]),
            .blockQuote([.paragraph([.text("Inner")])]),
        ])
        XCTAssertEqual(document.blocks, [expected])
    }

    // MARK: - Thematic Breaks

    func test_parse_thematicBreak_withHyphens_producesThematicBreak() {
        let document = MarkdownParser.parse("---")

        XCTAssertEqual(document.blocks, [.thematicBreak])
    }

    func test_parse_thematicBreak_withAsterisks_producesThematicBreak() {
        let document = MarkdownParser.parse("***")

        XCTAssertEqual(document.blocks, [.thematicBreak])
    }

    func test_parse_thematicBreak_withUnderscores_producesThematicBreak() {
        let document = MarkdownParser.parse("___")

        XCTAssertEqual(document.blocks, [.thematicBreak])
    }

    // MARK: - Links

    func test_parse_inlineLink_producesLinkInlineWithDestination() {
        let document = MarkdownParser.parse("[text](https://example.com)")

        XCTAssertEqual(document.blocks, [
            .paragraph([.link(inlines: [.text("text")], destination: "https://example.com")])
        ])
    }

    // MARK: - Images

    func test_parse_imageWithTitle_producesImageInlineWithTitle() {
        let document = MarkdownParser.parse(#"![alt](https://example.com/img.png "title")"#)

        XCTAssertEqual(document.blocks, [
            .paragraph([.image(alt: "alt", source: "https://example.com/img.png", title: "title")])
        ])
    }

    func test_parse_imageWithoutTitle_hasNilTitle() {
        let document = MarkdownParser.parse("![alt](https://example.com/img.png)")

        XCTAssertEqual(document.blocks, [
            .paragraph([.image(alt: "alt", source: "https://example.com/img.png", title: nil)])
        ])
    }

    // MARK: - Footnotes

    func test_parse_footnoteReferencedAndDefined_producesFootnoteReferenceAndDefinition() {
        let source = """
        Some text[^1] more text.

        [^1]: The footnote body.
        """

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([
                .text("Some text"),
                .footnoteReference(label: "1", index: 1),
                .text(" more text."),
            ])
        ])
        XCTAssertEqual(document.footnotes, [
            MarkdownFootnote(id: "1", index: 1, content: [.text("The footnote body.")])
        ])
    }

    func test_parse_footnotesReferencedOutOfDefinitionOrder_numberedByFirstReference() {
        let source = """
        First[^b] and second[^a].

        [^a]: Footnote A.
        [^b]: Footnote B.
        """

        let document = MarkdownParser.parse(source)

        // [^b] is referenced first in the body even though [^a] is defined first,
        // so [^b] must get index 1 and [^a] must get index 2.
        XCTAssertEqual(document.blocks, [
            .paragraph([
                .text("First"),
                .footnoteReference(label: "b", index: 1),
                .text(" and second"),
                .footnoteReference(label: "a", index: 2),
                .text("."),
            ])
        ])
        XCTAssertEqual(document.footnotes, [
            MarkdownFootnote(id: "b", index: 1, content: [.text("Footnote B.")]),
            MarkdownFootnote(id: "a", index: 2, content: [.text("Footnote A.")]),
        ])
    }

    func test_parse_footnoteWithWordLabel_isSupported() {
        let source = """
        Note here[^note].

        [^note]: Explanation text.
        """

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([
                .text("Note here"),
                .footnoteReference(label: "note", index: 1),
                .text("."),
            ])
        ])
        XCTAssertEqual(document.footnotes, [
            MarkdownFootnote(id: "note", index: 1, content: [.text("Explanation text.")])
        ])
    }

    func test_parse_footnoteReferenceWithoutMatchingDefinition_fallsBackToLiteralText() {
        // Contract: `[^label]` with no corresponding `[^label]: ...` definition anywhere
        // in the document has nothing to link to (cmark has no footnote extension of its
        // own, and our pre-processing pass only rewrites references that have a matching
        // definition). The expected, documented fallback is that it is left completely
        // alone and rendered as ordinary literal text — including the brackets and caret —
        // rather than becoming a dangling/broken footnote reference.
        let source = "Plain text [^1] without definition."

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([.text("Plain text [^1] without definition.")])
        ])
        XCTAssertEqual(document.footnotes, [])
    }

    // MARK: - Inline Formatting

    func test_parse_emphasis_producesEmphasisInline() {
        let document = MarkdownParser.parse("*italic text*")

        XCTAssertEqual(document.blocks, [.paragraph([.emphasis([.text("italic text")])])])
    }

    func test_parse_strong_producesStrongInline() {
        let document = MarkdownParser.parse("**bold text**")

        XCTAssertEqual(document.blocks, [.paragraph([.strong([.text("bold text")])])])
    }

    func test_parse_strikethrough_producesStrikethroughInline() {
        let document = MarkdownParser.parse("~~strike text~~")

        XCTAssertEqual(document.blocks, [.paragraph([.strikethrough([.text("strike text")])])])
    }

    func test_parse_inlineCode_producesCodeInline() {
        let document = MarkdownParser.parse("`code text`")

        XCTAssertEqual(document.blocks, [.paragraph([.code("code text")])])
    }

    func test_parse_mixedInlineFormatting_preservesOrderOfRuns() {
        let source = "**bold** and *italic* and `code` and ~~strike~~ end."

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([
                .strong([.text("bold")]),
                .text(" and "),
                .emphasis([.text("italic")]),
                .text(" and "),
                .code("code"),
                .text(" and "),
                .strikethrough([.text("strike")]),
                .text(" end."),
            ])
        ])
    }

    // MARK: - Line Breaks

    func test_parse_singleNewlineWithinParagraph_producesSoftBreak() {
        let source = "Line one\nLine two"

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([.text("Line one"), .softBreak, .text("Line two")])
        ])
    }

    func test_parse_trailingDoubleSpaceNewline_producesHardLineBreak() {
        let source = "Line one  \nLine two"

        let document = MarkdownParser.parse(source)

        XCTAssertEqual(document.blocks, [
            .paragraph([.text("Line one"), .lineBreak, .text("Line two")])
        ])
    }
}
