import XCTest
@testable import NeutrinoNotes

/// Tests for the tag picker's search field, which is both the filter and the only way to create a
/// tag from a note. The rules live in static functions precisely so they can be checked here
/// without hosting the view or reaching the server.
final class TagPickerSheetTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTags(_ names: [String]) -> [NoteTag] {
        names.enumerated().map { NoteTag(id: "t\($0.offset)", name: $0.element, createdAt: Date()) }
    }

    // MARK: - Filtering

    func test_filter_emptyQuery_returnsEveryTag() {
        let tags = makeTags(["Work", "Personal", "Taxes"])

        XCTAssertEqual(TagPickerSheet.filter(tags, matching: "").map(\.name),
                       ["Work", "Personal", "Taxes"])
    }

    func test_filter_whitespaceOnlyQuery_returnsEveryTag() {
        let tags = makeTags(["Work", "Personal"])

        XCTAssertEqual(TagPickerSheet.filter(tags, matching: "   ").count, 2)
    }

    func test_filter_matchesSubstringsCaseInsensitively() {
        let tags = makeTags(["Work", "Homework", "Personal"])

        XCTAssertEqual(TagPickerSheet.filter(tags, matching: "work").map(\.name), ["Work", "Homework"])
    }

    func test_filter_ignoresDiacritics() {
        let tags = makeTags(["Café", "Work"])

        XCTAssertEqual(TagPickerSheet.filter(tags, matching: "cafe").map(\.name), ["Café"])
    }

    func test_filter_trimsTheQuery() {
        let tags = makeTags(["Work", "Personal"])

        XCTAssertEqual(TagPickerSheet.filter(tags, matching: "  Work  ").map(\.name), ["Work"])
    }

    func test_filter_noMatch_isEmpty() {
        XCTAssertTrue(TagPickerSheet.filter(makeTags(["Work"]), matching: "zzz").isEmpty)
    }

    // MARK: - Create Candidate

    func test_createCandidate_offersTheTypedName_whenNothingMatches() {
        let candidate = TagPickerSheet.createCandidate(for: "Taxes", in: makeTags(["Work"]))

        XCTAssertEqual(candidate, "Taxes")
    }

    func test_createCandidate_isNil_whenTheQueryIsBlank() {
        XCTAssertNil(TagPickerSheet.createCandidate(for: "   ", in: makeTags(["Work"])))
    }

    /// The server rejects a duplicate name whatever its case, so offering to create "work" beside
    /// an existing "Work" would only earn a 409.
    func test_createCandidate_isNil_whenATagAlreadyHasThatNameInAnyCase() {
        XCTAssertNil(TagPickerSheet.createCandidate(for: "work", in: makeTags(["Work"])))
    }

    /// A partial match still offers creation — "Home" is a different tag from "Homework".
    func test_createCandidate_offersCreation_whenTheMatchIsOnlyPartial() {
        XCTAssertEqual(TagPickerSheet.createCandidate(for: "Home", in: makeTags(["Homework"])), "Home")
    }

    func test_createCandidate_isTrimmed() {
        XCTAssertEqual(TagPickerSheet.createCandidate(for: "  Taxes  ", in: []), "Taxes")
    }
}
