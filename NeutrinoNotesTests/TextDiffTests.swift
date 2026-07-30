import XCTest
@testable import NeutrinoNotes

/// Tests for the line diff behind version comparison. Pure value-in/value-out — no view,
/// no network, no crypto.
final class TextDiffTests: XCTestCase {

    // MARK: - Helpers

    private func kinds(_ old: String, _ new: String) -> [TextDiff.Kind] {
        TextDiff.compare(old, new).map(\.kind)
    }

    private func texts(_ old: String, _ new: String, of kind: TextDiff.Kind) -> [String] {
        TextDiff.compare(old, new).filter { $0.kind == kind }.map(\.text)
    }

    // MARK: - Identical

    func test_identicalText_isAllUnchanged() {
        let text = "# Title\n\nSome body.\n- one\n- two"
        XCTAssertEqual(kinds(text, text), Array(repeating: .unchanged, count: 5))
        XCTAssertTrue(TextDiff.isIdentical(text, text))
    }

    func test_trailingNewline_isNotAChange() {
        XCTAssertTrue(TextDiff.isIdentical("a\nb", "a\nb\n"))
        XCTAssertEqual(kinds("a\nb", "a\nb\n"), [.unchanged, .unchanged])
    }

    func test_emptyStrings_produceASingleUnchangedEmptyLine() {
        XCTAssertEqual(kinds("", ""), [.unchanged])
        XCTAssertTrue(TextDiff.isIdentical("", ""))
    }

    // MARK: - Pure insert / delete

    func test_appendedLines_areInserted() {
        XCTAssertEqual(kinds("a\nb", "a\nb\nc"), [.unchanged, .unchanged, .inserted])
        XCTAssertEqual(texts("a\nb", "a\nb\nc", of: .inserted), ["c"])
    }

    func test_removedLines_areDeleted() {
        XCTAssertEqual(kinds("a\nb\nc", "a\nc"), [.unchanged, .deleted, .unchanged])
        XCTAssertEqual(texts("a\nb\nc", "a\nc", of: .deleted), ["b"])
    }

    func test_insertingIntoEmpty_marksEverythingInserted() {
        XCTAssertEqual(kinds("", "a\nb"), [.deleted, .inserted, .inserted])
    }

    // MARK: - Edits

    func test_changedLine_readsAsDeleteThenInsert() {
        let diff = TextDiff.compare("a\nb\nc", "a\nB\nc")
        XCTAssertEqual(diff.map(\.kind), [.unchanged, .deleted, .inserted, .unchanged])
        XCTAssertEqual(diff.map(\.text), ["a", "b", "B", "c"])
    }

    func test_interleavedEdits_keepUnchangedLinesInPlace() {
        let old = "intro\nalpha\nshared\nbeta\nend"
        let new = "intro\nshared\ngamma\nend"
        let diff = TextDiff.compare(old, new)

        XCTAssertEqual(texts(old, new, of: .deleted), ["alpha", "beta"])
        XCTAssertEqual(texts(old, new, of: .inserted), ["gamma"])
        // Every line of both revisions is accounted for exactly once.
        XCTAssertEqual(diff.count, 6)
        XCTAssertEqual(diff.filter { $0.kind != .inserted }.map(\.text),
                       old.components(separatedBy: "\n"))
        XCTAssertEqual(diff.filter { $0.kind != .deleted }.map(\.text),
                       new.components(separatedBy: "\n"))
    }

    func test_reorderedLines_areNotReportedAsUnchangedInPlace() {
        let diff = TextDiff.compare("a\nb", "b\na")
        // One line survives as the common subsequence; the other is a delete/insert pair.
        XCTAssertEqual(diff.filter { $0.kind == .unchanged }.count, 1)
        XCTAssertEqual(diff.filter { $0.kind == .deleted }.count, 1)
        XCTAssertEqual(diff.filter { $0.kind == .inserted }.count, 1)
    }

    func test_ids_areUniqueAndSequential() {
        let diff = TextDiff.compare("a\nb\nc", "a\nx\nc")
        XCTAssertEqual(diff.map(\.id), Array(0..<diff.count))
    }

    // MARK: - Oversized input

    func test_inputTooLargeToDiff_fallsBackToWholesaleReplacement() {
        // Common prefix/suffix are stripped before the table is sized, so make the differing
        // middle itself exceed the cap.
        let lineCount = Int(Double(TextDiff.maxTableCells).squareRoot()) + 50
        let old = (0..<lineCount).map { "old line \($0)" }.joined(separator: "\n")
        let new = (0..<lineCount).map { "new line \($0)" }.joined(separator: "\n")

        let diff = TextDiff.compare(old, new)

        XCTAssertEqual(diff.filter { $0.kind == .unchanged }.count, 0)
        XCTAssertEqual(diff.filter { $0.kind == .deleted }.count, lineCount)
        XCTAssertEqual(diff.filter { $0.kind == .inserted }.count, lineCount)
        // Deletions come first, so the fallback still reads as "this became that".
        XCTAssertEqual(diff.prefix(lineCount).allSatisfy { $0.kind == .deleted }, true)
    }

    func test_largeInputWithSmallEdit_stillDiffsLineByLine() {
        // A big document is fine as long as the *difference* is small, because the shared
        // prefix and suffix are stripped before the table is allocated.
        let lines = (0..<5_000).map { "line \($0)" }
        let old = lines.joined(separator: "\n")
        var edited = lines
        edited[2_500] = "line 2500 — edited"
        let new = edited.joined(separator: "\n")

        let diff = TextDiff.compare(old, new)

        XCTAssertEqual(diff.filter { $0.kind == .deleted }.map(\.text), ["line 2500"])
        XCTAssertEqual(diff.filter { $0.kind == .inserted }.map(\.text), ["line 2500 — edited"])
        XCTAssertEqual(diff.filter { $0.kind == .unchanged }.count, lines.count - 1)
    }
}
