import XCTest
@testable import NeutrinoNotes

final class MarkdownChecklistTests: XCTestCase {

    // MARK: - Helpers

    /// The Return action for a caret placed at the end of `text`, which is where it sits while a
    /// list is being typed.
    private func actionAtEnd(of text: String) -> MarkdownChecklist.ReturnAction? {
        let string = text as NSString
        return MarkdownChecklist.returnAction(in: string, replacing: NSRange(location: string.length, length: 0))
    }

    private func action(in text: String, caretAfter prefix: String) -> MarkdownChecklist.ReturnAction? {
        let caret = (prefix as NSString).length
        return MarkdownChecklist.returnAction(in: text as NSString, replacing: NSRange(location: caret, length: 0))
    }

    // MARK: - Continuing a List

    func test_returnAction_afterUncheckedItem_startsNextItem() {
        XCTAssertEqual(actionAtEnd(of: "- [ ] Buy milk"), .continueList("\n- [ ] "))
    }

    func test_returnAction_afterCheckedItem_startsNextItemUnchecked() {
        XCTAssertEqual(actionAtEnd(of: "- [x] Buy milk"), .continueList("\n- [ ] "))
        XCTAssertEqual(actionAtEnd(of: "- [X] Buy milk"), .continueList("\n- [ ] "))
    }

    func test_returnAction_keepsTheBulletCharacter() {
        XCTAssertEqual(actionAtEnd(of: "* [ ] Buy milk"), .continueList("\n* [ ] "))
        XCTAssertEqual(actionAtEnd(of: "+ [ ] Buy milk"), .continueList("\n+ [ ] "))
    }

    func test_returnAction_keepsIndentation() {
        XCTAssertEqual(actionAtEnd(of: "- [ ] Shopping\n    - [ ] Milk"), .continueList("\n    - [ ] "))
        XCTAssertEqual(actionAtEnd(of: "\t- [ ] Milk"), .continueList("\n\t- [ ] "))
    }

    func test_returnAction_orderedItem_incrementsTheNumber() {
        XCTAssertEqual(actionAtEnd(of: "3. [ ] Buy milk"), .continueList("\n4. [ ] "))
        XCTAssertEqual(actionAtEnd(of: "1) [x] Buy milk"), .continueList("\n2) [ ] "))
    }

    func test_returnAction_onlyLooksAtTheCaretsOwnLine() {
        XCTAssertEqual(actionAtEnd(of: "# Groceries\n\n- [ ] Buy milk"), .continueList("\n- [ ] "))
    }

    func test_returnAction_midItem_stillStartsNextItem() {
        // Splitting an item in two: the second half becomes the new item's text.
        XCTAssertEqual(action(in: "- [ ] Buy milk and eggs", caretAfter: "- [ ] Buy milk"),
                       .continueList("\n- [ ] "))
    }

    func test_returnAction_caretRightAfterMarker_startsNextItem() {
        XCTAssertEqual(action(in: "- [ ] Buy milk", caretAfter: "- [ ]"), .continueList("\n- [ ] "))
    }

    // MARK: - Ending a List

    func test_returnAction_onEmptyItem_removesTheMarker() {
        XCTAssertEqual(actionAtEnd(of: "- [ ] Buy milk\n- [ ] "),
                       .endList(NSRange(location: 15, length: 6)))
    }

    func test_returnAction_onEmptyItem_withoutTrailingSpace_removesTheMarker() {
        XCTAssertEqual(actionAtEnd(of: "- [ ]"), .endList(NSRange(location: 0, length: 5)))
    }

    func test_returnAction_onEmptyItem_removesIndentationToo() {
        XCTAssertEqual(actionAtEnd(of: "    - [ ] "), .endList(NSRange(location: 0, length: 10)))
    }

    func test_returnAction_onEmptyItem_leavesTheRestOfTheNoteAlone() {
        // The marker's range must stop at the newline, not swallow the line below.
        XCTAssertEqual(actionAtEnd(of: "- [ ] "), .endList(NSRange(location: 0, length: 6)))
    }

    func test_returnAction_onEmptyOrderedItem_removesTheMarker() {
        XCTAssertEqual(actionAtEnd(of: "1. [ ] "), .endList(NSRange(location: 0, length: 7)))
    }

    func test_returnAction_onEmptyItemInTheMiddleOfANote_removesOnlyThatLine() {
        let text = "- [ ] Buy milk\n- [ ] \n- [ ] Buy eggs"
        XCTAssertEqual(action(in: text, caretAfter: "- [ ] Buy milk\n- [ ] "),
                       .endList(NSRange(location: 15, length: 6)))
    }

    // MARK: - Lines That Aren't Checklist Items

    func test_returnAction_plainText_isNotHandled() {
        XCTAssertNil(actionAtEnd(of: "Just a note"))
        XCTAssertNil(actionAtEnd(of: ""))
    }

    func test_returnAction_plainBulletList_isNotHandled() {
        XCTAssertNil(actionAtEnd(of: "- Buy milk"))
        XCTAssertNil(actionAtEnd(of: "1. Buy milk"))
    }

    func test_returnAction_checkboxNotAtTheStartOfTheLine_isNotHandled() {
        XCTAssertNil(actionAtEnd(of: "See - [ ] below"))
    }

    func test_returnAction_malformedCheckbox_isNotHandled() {
        XCTAssertNil(actionAtEnd(of: "- [] Buy milk"))
        XCTAssertNil(actionAtEnd(of: "- [y] Buy milk"))
        XCTAssertNil(actionAtEnd(of: "-[ ] Buy milk"))
    }

    func test_returnAction_caretInsideTheMarker_isNotHandled() {
        // Editing the box itself, rather than finishing the item.
        XCTAssertNil(action(in: "- [ ] Buy milk", caretAfter: "- ["))
        XCTAssertNil(action(in: "- [ ] Buy milk", caretAfter: ""))
    }

    // MARK: - Selections

    func test_returnAction_replacingASelection_stillStartsNextItem() {
        // Return with "eggs" selected replaces it and continues the list.
        let text = "- [ ] Buy eggs"
        let action = MarkdownChecklist.returnAction(in: text as NSString,
                                                    replacing: NSRange(location: 10, length: 4))
        XCTAssertEqual(action, .continueList("\n- [ ] "))
    }

    func test_returnAction_replacingASelectionOnAnEmptyItem_doesNotEndTheList() {
        // The marker is selected, so Return is a replacement of it — deleting it as well would
        // throw away text the user meant to overwrite.
        let text = "- [ ] "
        let action = MarkdownChecklist.returnAction(in: text as NSString,
                                                    replacing: NSRange(location: 0, length: 6))
        XCTAssertNil(action)
    }

    // MARK: - Range Safety

    func test_returnAction_rangeBeyondTheText_isNotHandled() {
        XCTAssertNil(MarkdownChecklist.returnAction(in: "- [ ] Buy milk" as NSString,
                                                    replacing: NSRange(location: 99, length: 0)))
    }
}
