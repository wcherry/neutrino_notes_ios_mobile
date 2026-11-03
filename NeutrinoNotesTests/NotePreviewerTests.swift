import XCTest
@testable import NeutrinoNotes

/// Page one's signature: what decides whether an edit redraws the note's Drive preview.
@MainActor
final class NotePreviewerTests: XCTestCase {

    private var longNote: [String] { (1...100).map { "Line \($0)" } }

    func testAnEditBelowPageOneKeepsTheSignature() {
        var edited = longNote
        edited[90] = "Rewritten near the end"
        XCTAssertEqual(NotePreviewer.signature(of: edited.joined(separator: "\n")),
                       NotePreviewer.signature(of: longNote.joined(separator: "\n")))
    }

    func testAnEditOnPageOneChangesTheSignature() {
        var edited = longNote
        edited[0] = "# A new heading"
        XCTAssertNotEqual(NotePreviewer.signature(of: edited.joined(separator: "\n")),
                          NotePreviewer.signature(of: longNote.joined(separator: "\n")))
    }

    func testHeadingsAndBulletsAreStyledForThePreview() {
        let styled = NotePreviewer.styled("# Title\n- item").string
        XCTAssertEqual(styled, "Title\n•  item\n")
    }
}
