import Foundation

// MARK: - FileLink

/// One end of a link in Drive's cross-file link graph, as
/// `GET /api/v1/links/{fileId}/backlinks` reports it.
///
/// The graph is file-type-agnostic on purpose (`src/links/`): a note can be linked from a doc, and
/// this app has to render that honestly rather than pretend everything pointing at a note is a
/// note. `title` is the linking file's Drive name, which is stored in the clear — the same reason
/// the server can resolve `[[titles]]` at all while note bodies stay encrypted.
struct FileLink: Identifiable, Hashable, Decodable {

    let id: String
    let title: String
    /// The server's short label for the source's MIME type: `note`, `doc`, `sheet`, `slide`,
    /// `diagram`, `drawing`, or `file` for anything it has no mapping for.
    let fileType: String

    // MARK: - Computed

    /// The Neutrino app that owns this file type, when one does.
    var kind: NeutrinoAppLink.Kind? {
        guard let kind = NeutrinoAppLink.Kind(rawValue: fileType), kind != .file else { return nil }
        return kind
    }

    /// True for the links this app can open itself; everything else is handed to its own app.
    var isNote: Bool {
        kind == .note
    }

    /// The name without the `.md` this app appends to the notes it creates — a backlinks list
    /// full of `.md` reads like a file browser, not like the titles the user typed.
    var displayTitle: String {
        WikiLink.displayTitle(for: title)
    }

    var systemImage: String {
        switch kind {
        case .note:    return "note.text"
        case .doc:     return "doc.richtext"
        case .sheet:   return "tablecells"
        case .slide:   return "rectangle.on.rectangle"
        case .diagram: return "flowchart"
        case .drawing: return "scribble"
        default:       return "doc"
        }
    }
}

// MARK: - BacklinksResponse

/// `GET /api/v1/links/{fileId}/backlinks`, and the body `PATCH /api/v1/links/{fileId}` answers with.
///
/// Note the asymmetry, which is the server's contract and not an oversight here: the PATCH sends
/// *outgoing* links and is answered with *incoming* ones.
struct BacklinksResponse: Decodable {
    let backlinks: [FileLink]
}
