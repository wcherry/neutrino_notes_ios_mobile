import Foundation

// MARK: - WikiLinkIndex

/// Resolves a `[[title]]` to a note, on the device.
///
/// Resolution happens twice for every link, in two different places, and only one of them is the
/// server's job. The server resolves titles when it stores the graph; the app has to resolve them
/// again to decide whether to draw a link as live or broken, and to know what to open when it is
/// tapped. There is no endpoint for the second question — the drive-wide FTS search this app's
/// Epic 11 plan describes no longer exists server-side, and the snapshot index that replaced it is
/// ciphertext the server cannot query. So the index is built from listings the app already loads
/// (`GET /api/v1/drive?type=note` is a whole-drive note listing, not just the root).
///
/// Titles are matched the way [WikiLink.indexKey] spells them: trimmed, `.md`-less, case-folded.
struct WikiLinkIndex: Equatable {

    // MARK: - Storage

    private let byKey: [String: NoteItem]
    /// Sorted for the autocomplete menu, so suggestion order doesn't depend on dictionary order.
    private let sortedItems: [NoteItem]

    // MARK: - Init

    init(items: [NoteItem] = []) {
        var byKey: [String: NoteItem] = [:]
        let notes = items.filter { $0.type == .file && !$0.isTrashed }

        for note in notes {
            for key in Set([WikiLink.indexKey(for: note.name), note.name.lowercased()]) where !key.isEmpty {
                // Two notes can legitimately share a title. The server keeps whichever its own
                // listing happened to yield last; here the most recently edited one wins, which at
                // least makes the choice predictable to the person who typed the link.
                if let existing = byKey[key], existing.modifiedAt >= note.modifiedAt { continue }
                byKey[key] = note
            }
        }

        self.byKey = byKey
        self.sortedItems = notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Lookup

    var isEmpty: Bool { byKey.isEmpty }

    /// The note a `[[title]]` points at, or nil when nothing this device knows about matches.
    ///
    /// Nil is not the same as "no such note": a note in a folder this session never listed is
    /// invisible here even though the server would resolve it. That is why an unresolved link is
    /// still tappable in the editor rather than being rendered as an error.
    func item(for title: String) -> NoteItem? {
        byKey[WikiLink.indexKey(for: title)]
    }

    func contains(_ title: String) -> Bool {
        item(for: title) != nil
    }

    // MARK: - Suggestions

    /// Notes to offer for a half-typed `[[que`. Prefix matches first, then anything containing the
    /// query, each group newest first. An empty query offers the most recently edited notes, which
    /// is the useful answer immediately after typing `[[`.
    func suggestions(for query: String, limit: Int = 8) -> [NoteItem] {
        let needle = WikiLink.indexKey(for: query)
        guard !needle.isEmpty else { return Array(sortedItems.prefix(limit)) }

        var prefixed: [NoteItem] = []
        var contained: [NoteItem] = []
        for note in sortedItems {
            let key = WikiLink.indexKey(for: note.name)
            if key.hasPrefix(needle) {
                prefixed.append(note)
            } else if key.contains(needle) {
                contained.append(note)
            }
        }
        return Array((prefixed + contained).prefix(limit))
    }
}
