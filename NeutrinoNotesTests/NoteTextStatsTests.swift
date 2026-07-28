import XCTest
@testable import NeutrinoNotes

final class NoteTextStatsTests: XCTestCase {

    // MARK: - Word / Character Count

    func test_compute_emptyText_hasZeroCounts() {
        let stats = NoteTextStats.compute(from: "")

        XCTAssertEqual(stats.wordCount, 0)
        XCTAssertEqual(stats.characterCount, 0)
        XCTAssertEqual(stats.readingTimeMinutes, 0)
    }

    func test_compute_singleWord_countsOneWord() {
        let stats = NoteTextStats.compute(from: "Hello")

        XCTAssertEqual(stats.wordCount, 1)
        XCTAssertEqual(stats.characterCount, 5)
    }

    func test_compute_multipleWords_splitsOnWhitespaceAndNewlines() {
        let stats = NoteTextStats.compute(from: "Hello world\nfrom  Neutrino Notes")

        XCTAssertEqual(stats.wordCount, 5)
    }

    func test_compute_characterCount_includesWhitespace() {
        let stats = NoteTextStats.compute(from: "a b")

        XCTAssertEqual(stats.characterCount, 3)
    }

    func test_compute_whitespaceOnlyText_hasZeroWordCount() {
        let stats = NoteTextStats.compute(from: "   \n\n  ")

        XCTAssertEqual(stats.wordCount, 0)
    }

    // MARK: - Reading Time

    func test_compute_underTwoHundredWords_roundsUpToOneMinute() {
        let text = Array(repeating: "word", count: 50).joined(separator: " ")
        let stats = NoteTextStats.compute(from: text)

        XCTAssertEqual(stats.readingTimeMinutes, 1)
    }

    func test_compute_exactlyTwoHundredWords_isOneMinute() {
        let text = Array(repeating: "word", count: 200).joined(separator: " ")
        let stats = NoteTextStats.compute(from: text)

        XCTAssertEqual(stats.readingTimeMinutes, 1)
    }

    func test_compute_twoHundredOneWords_roundsUpToTwoMinutes() {
        let text = Array(repeating: "word", count: 201).joined(separator: " ")
        let stats = NoteTextStats.compute(from: text)

        XCTAssertEqual(stats.readingTimeMinutes, 2)
    }

    func test_compute_emptyText_hasZeroReadingTime() {
        let stats = NoteTextStats.compute(from: "")
        XCTAssertEqual(stats.readingTimeMinutes, 0)
    }

    // MARK: - readingTimeText

    func test_readingTimeText_oneMinute_isSingular() {
        let stats = NoteTextStats(wordCount: 10, characterCount: 50, readingTimeMinutes: 1)
        XCTAssertEqual(stats.readingTimeText, "1 min read")
    }

    func test_readingTimeText_multipleMinutes_isPlural() {
        let stats = NoteTextStats(wordCount: 500, characterCount: 2500, readingTimeMinutes: 3)
        XCTAssertEqual(stats.readingTimeText, "3 min read")
    }
}
