import Foundation

// MARK: - TextDiff

/// A line-level diff between two revisions of a note, used by `VersionCompareView`.
///
/// Line-level rather than the word-level diff the web app uses: Markdown is edited a line at
/// a time, a phone-width column has no room for intra-line highlighting, and an O(words²)
/// table is far more expensive than an O(lines²) one for the same document.
enum TextDiff {

    // MARK: - Line

    enum Kind {
        case unchanged
        case inserted
        case deleted
    }

    struct Line: Identifiable, Equatable {
        /// Position in the rendered diff; stable for `ForEach` and meaningless otherwise.
        let id: Int
        let kind: Kind
        let text: String
    }

    // MARK: - Limits

    /// Cap on the LCS table (`old.count * new.count`). Beyond this the comparison degrades to
    /// "everything in the middle was replaced" rather than allocating an unbounded table —
    /// 250k cells is a few megabytes, and two notes that differ across thousands of lines
    /// have no readable line-by-line diff anyway.
    static let maxTableCells = 250_000

    // MARK: - Diff

    /// Returns every line of both revisions in order, tagged as unchanged, inserted, or deleted.
    static func compare(_ old: String, _ new: String) -> [Line] {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)

        // Shared head and tail are the common case for an edit and cost nothing to strip.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix..<(newLines.count - suffix)])

        var result: [String] = []
        var kinds: [Kind] = []

        for line in oldLines[0..<prefix] {
            result.append(line)
            kinds.append(.unchanged)
        }

        let middle = oldMiddle.count * newMiddle.count <= maxTableCells
            ? diffMiddle(oldMiddle, newMiddle)
            : replaceWholesale(oldMiddle, newMiddle)
        for (kind, text) in middle {
            result.append(text)
            kinds.append(kind)
        }

        for line in oldLines[(oldLines.count - suffix)...] {
            result.append(line)
            kinds.append(.unchanged)
        }

        return zip(kinds, result).enumerated().map { Line(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    /// True when the two revisions are identical line for line.
    static func isIdentical(_ old: String, _ new: String) -> Bool {
        lines(of: old) == lines(of: new)
    }

    // MARK: - Private

    /// Splits into lines, dropping the empty trailing element a final newline produces so that
    /// "a\n" and "a" compare equal — the editor's trailing newline is not a meaningful change.
    private static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Classic LCS-table diff. Only ever called on the differing middle, and only when the
    /// table fits within `maxTableCells`.
    private static func diffMiddle(_ old: [String], _ new: [String]) -> [(Kind, String)] {
        let m = old.count
        let n = new.count
        guard m > 0 else { return new.map { (.inserted, $0) } }
        guard n > 0 else { return old.map { (.deleted, $0) } }

        // table[i * (n + 1) + j] = LCS length of old[i...] and new[j...], filled back to front.
        var table = [Int](repeating: 0, count: (m + 1) * (n + 1))
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                table[i * (n + 1) + j] = old[i] == new[j]
                    ? table[(i + 1) * (n + 1) + (j + 1)] + 1
                    : max(table[(i + 1) * (n + 1) + j], table[i * (n + 1) + (j + 1)])
            }
        }

        var out: [(Kind, String)] = []
        var i = 0
        var j = 0
        while i < m || j < n {
            if i < m, j < n, old[i] == new[j] {
                out.append((.unchanged, old[i]))
                i += 1
                j += 1
            } else if i < m, j >= n || table[(i + 1) * (n + 1) + j] >= table[i * (n + 1) + (j + 1)] {
                // Ties break towards the deletion so a replaced line reads "− old" then "+ new".
                out.append((.deleted, old[i]))
                i += 1
            } else {
                out.append((.inserted, new[j]))
                j += 1
            }
        }
        return out
    }

    /// Fallback for inputs too large to diff line by line: the whole middle reads as replaced.
    private static func replaceWholesale(_ old: [String], _ new: [String]) -> [(Kind, String)] {
        old.map { (.deleted, $0) } + new.map { (.inserted, $0) }
    }
}
