import Foundation

// MARK: - NoteTextStats

/// Word/character counts and estimated reading time for a note's Markdown body.
/// Pulled out of the editor view so the math can be unit tested directly.
struct NoteTextStats: Equatable {
    let wordCount: Int
    let characterCount: Int
    let readingTimeMinutes: Int

    static func compute(from text: String) -> NoteTextStats {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let wordCount = words.count
        let readingTimeMinutes = wordCount == 0 ? 0 : max(1, Int((Double(wordCount) / 200.0).rounded(.up)))
        return NoteTextStats(
            wordCount: wordCount,
            characterCount: text.count,
            readingTimeMinutes: readingTimeMinutes
        )
    }

    var readingTimeText: String {
        readingTimeMinutes <= 1 ? "1 min read" : "\(readingTimeMinutes) min read"
    }
}
