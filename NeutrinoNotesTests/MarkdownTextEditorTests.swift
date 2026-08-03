import SwiftUI
import UIKit
import XCTest
@testable import NeutrinoNotes

/// Drives the editor's delegate against a real `UITextView`, which is where checklist continuation
/// actually has to land: the right text, the caret after the marker, and the binding in step.
@MainActor
final class MarkdownTextEditorTests: XCTestCase {

    // MARK: - Harness

    /// Stands in for the `@State` the editor's binding is normally rooted in.
    private final class TextStore {
        var value: String
        init(_ value: String) { self.value = value }
        var binding: Binding<String> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private struct Harness {
        let textView: UITextView
        let coordinator: MarkdownTextEditor.Coordinator
        let controller: MarkdownTextEditorController
        let store: TextStore

        /// Types Return with the caret at `caret`, and reports whether the text view was left to
        /// insert the newline itself.
        @discardableResult
        func typeReturn(at caret: Int) -> Bool {
            textView.selectedRange = NSRange(location: caret, length: 0)
            return coordinator.textView(textView,
                                        shouldChangeTextIn: textView.selectedRange,
                                        replacementText: "\n")
        }

        /// Types `string` at the end of the note, the way the text view reports it: the text
        /// changes, then the delegate hears about it.
        func type(_ string: String) {
            textView.text += string
            textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
            coordinator.textViewDidChange(textView)
        }

        /// Moves the caret without changing the text, as tapping into the note does.
        func moveCaret(to location: Int) {
            textView.selectedRange = NSRange(location: location, length: 0)
            coordinator.textViewDidChangeSelection(textView)
        }
    }

    private func makeHarness(text: String) -> Harness {
        let store = TextStore(text)
        let controller = MarkdownTextEditorController()
        let coordinator = MarkdownTextEditor.Coordinator(text: store.binding, controller: controller)
        let textView = UITextView()
        textView.delegate = coordinator
        textView.text = text
        controller.attach(textView, coordinator: coordinator)
        return Harness(textView: textView, coordinator: coordinator, controller: controller, store: store)
    }

    // MARK: - Continuing a List

    func test_return_afterChecklistItem_insertsTheNextMarkerAndPutsTheCaretAfterIt() {
        let harness = makeHarness(text: "- [ ] Buy milk")

        let handledByTextView = harness.typeReturn(at: 14)

        XCTAssertFalse(handledByTextView)
        XCTAssertEqual(harness.textView.text, "- [ ] Buy milk\n- [ ] ")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 21, length: 0))
        XCTAssertEqual(harness.store.value, harness.textView.text)
    }

    func test_return_midNote_leavesTheTextBelowIntact() {
        let harness = makeHarness(text: "- [ ] Buy milk\n\nSee you Tuesday.")

        harness.typeReturn(at: 14)

        XCTAssertEqual(harness.textView.text, "- [ ] Buy milk\n- [ ] \n\nSee you Tuesday.")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 21, length: 0))
    }

    // MARK: - Ending a List

    func test_return_onAnEmptyChecklistItem_removesTheMarkerAndInsertsNoNewline() {
        let harness = makeHarness(text: "- [ ] Buy milk\n- [ ] ")

        let handledByTextView = harness.typeReturn(at: 21)

        XCTAssertFalse(handledByTextView)
        XCTAssertEqual(harness.textView.text, "- [ ] Buy milk\n")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 15, length: 0))
        XCTAssertEqual(harness.store.value, harness.textView.text)
    }

    func test_return_onAnEmptyChecklistItemMidNote_removesOnlyThatMarker() {
        let harness = makeHarness(text: "- [ ] Buy milk\n- [ ] \nSee you Tuesday.")

        harness.typeReturn(at: 21)

        XCTAssertEqual(harness.textView.text, "- [ ] Buy milk\n\nSee you Tuesday.")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 15, length: 0))
    }

    // MARK: - Everything Else

    func test_return_onAPlainLine_isLeftToTheTextView() {
        let harness = makeHarness(text: "Just a note")

        let handledByTextView = harness.typeReturn(at: 11)

        XCTAssertTrue(handledByTextView)
        XCTAssertEqual(harness.textView.text, "Just a note", "the delegate must not edit the text itself")
    }

    func test_typingAnOrdinaryCharacter_isLeftToTheTextView() {
        let harness = makeHarness(text: "- [ ] Buy milk")

        let handledByTextView = harness.coordinator.textView(
            harness.textView,
            shouldChangeTextIn: NSRange(location: 14, length: 0),
            replacementText: "!"
        )

        XCTAssertTrue(handledByTextView)
    }

    // MARK: - The Slash Menu

    func test_slash_atTheStartOfAnEmptyNote_opensTheMenu() {
        let harness = makeHarness(text: "")

        harness.type("/")

        XCTAssertEqual(harness.controller.slashCommand?.query, "")
    }

    func test_slash_onANewLine_opensTheMenu() {
        let harness = makeHarness(text: "Notes from today\n")

        harness.type("/")

        XCTAssertEqual(harness.controller.slashCommand?.query, "")
    }

    func test_typingAfterTheSlash_narrowsTheMenu() {
        let harness = makeHarness(text: "")

        harness.type("/")
        harness.type("h")
        harness.type("1")

        XCTAssertEqual(harness.controller.slashCommand?.query, "h1")
    }

    func test_slash_midLine_doesNotOpenTheMenu() {
        let harness = makeHarness(text: "and")

        harness.type("/")

        XCTAssertNil(harness.controller.slashCommand)
    }

    func test_typingASpaceAfterTheSlash_closesTheMenu() {
        let harness = makeHarness(text: "")

        harness.type("/")
        harness.type(" ")

        XCTAssertNil(harness.controller.slashCommand)
    }

    func test_movingTheCaretOffTheCommand_closesTheMenu() {
        let harness = makeHarness(text: "Notes\n")

        harness.type("/h")
        harness.moveCaret(to: 0)

        XCTAssertNil(harness.controller.slashCommand)
    }

    func test_tappingIntoALineThatStartsWithASlash_doesNotOpenTheMenu() {
        // A note about a file path is not a format request.
        let harness = makeHarness(text: "/usr/local/bin")

        harness.moveCaret(to: 4)

        XCTAssertNil(harness.controller.slashCommand)
    }

    // MARK: - Applying a Format

    func test_apply_writesTheFormatOverTheCommand() {
        let harness = makeHarness(text: "")
        harness.type("/h1")

        harness.controller.apply(format(id: "heading1"))

        XCTAssertEqual(harness.textView.text, "# ")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(harness.store.value, "# ")
        XCTAssertNil(harness.controller.slashCommand, "the menu closes once a format is chosen")
    }

    func test_apply_leavesTheCaretBetweenWrappingMarkers() {
        let harness = makeHarness(text: "")
        harness.type("/bold")

        harness.controller.apply(format(id: "bold"))

        XCTAssertEqual(harness.textView.text, "****")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 2, length: 0))
    }

    func test_apply_midNote_leavesTheRestOfTheNoteAlone() {
        let harness = makeHarness(text: "Shopping\n")
        harness.type("/todo")

        harness.controller.apply(format(id: "checklist"))

        XCTAssertEqual(harness.textView.text, "Shopping\n- [ ] ")
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 15, length: 0))
    }

    func test_apply_withNoMenuOpen_doesNothing() {
        let harness = makeHarness(text: "Buy milk")

        harness.controller.apply(format(id: "bold"))

        XCTAssertEqual(harness.textView.text, "Buy milk")
    }

    private func format(id: String) -> MarkdownFormat {
        guard let format = MarkdownFormat.all.first(where: { $0.id == id }) else {
            preconditionFailure("no format with id \(id)")
        }
        return format
    }

    // MARK: - Binding

    func test_textViewDidChange_publishesTheTextToTheBinding() {
        let harness = makeHarness(text: "")
        harness.textView.text = "Typed"

        harness.coordinator.textViewDidChange(harness.textView)

        XCTAssertEqual(harness.store.value, "Typed")
    }
}
