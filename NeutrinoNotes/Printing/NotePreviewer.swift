import UIKit
import NeutrinoCore
import NeutrinoPrint

// MARK: - NotePreviewer

/// Keeps the note's Drive preview — the picture in the Drive grid — showing its first page.
///
/// The page is the note laid out by NeutrinoPrint, as the other apps print theirs: the title as
/// the running header, the Markdown as lightly styled text. *When* it is redrawn is
/// ``DocumentPreviewGate``'s, the same rule the web editor follows: after a save, only when the
/// note's first lines changed — or when the server says the note has no preview at all.
@MainActor
final class NotePreviewer: ObservableObject {

    /// About as many lines of Markdown as page one holds — the same cut the web editor makes, so an
    /// edit further down redraws nothing.
    static let pageOneLines = 40

    private var gate: DocumentPreviewGate?
    /// The note the next render draws: the one the latest signature was taken from.
    private var text = ""
    private var title = ""

    /// Points the previewer at a note. Called once, when it has loaded.
    func attach(fileID: String, contentService: NoteContentService) {
        guard gate == nil else { return }
        gate = DocumentPreviewGate(
            render: { [weak self] in await self?.renderPageOne() },
            upload: { [contentService] jpeg in try await contentService.setPreview(jpeg, for: fileID) }
        )
    }

    /// The note is on screen: records page one as what Drive shows.
    ///
    /// No backfill here, unlike Docs: knowing whether the note *has* a preview would cost an
    /// `/info` round trip on every open, which this editor deliberately does not pay for an owned
    /// note. A note without one gets it on its first save instead, which reports the answer.
    func loaded(_ text: String, title: String) {
        guard let gate else { return }
        remember(text, title: title)
        let signature = Self.signature(of: text)
        Task { await gate.loaded(signature: signature, hasPreview: true) }
    }

    /// A save landed: redraws page one if it changed, or if the note has no preview.
    func saved(_ text: String, title: String, hasPreview: Bool) {
        guard let gate else { return }
        remember(text, title: title)
        let signature = Self.signature(of: text)
        Task { await gate.saved(signature: signature, hasPreview: hasPreview) }
    }

    private func remember(_ text: String, title: String) {
        self.text = text
        self.title = title
    }

    static func signature(of text: String) -> String {
        text.split(separator: "\n", maxSplits: pageOneLines, omittingEmptySubsequences: false)
            .prefix(pageOneLines)
            .joined(separator: "\n")
    }

    // MARK: - Rendering

    private func renderPageOne() -> Data? {
        let job = PrintJob(name: title, content: .attributedText(Self.styled(Self.signature(of: text))))
        return NeutrinoPrintPageRenderer(job: job).firstPageJPEG(maxEdge: DriveThumbnail.maxEdge)
    }

    /// Markdown as a reader would see it at a glance: headings set larger and bold, list markers
    /// as bullets, everything else as body text. A preview, not a renderer — inline formatting is
    /// left as typed.
    static func styled(_ markdown: String) -> NSAttributedString {
        let body = UIFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString()
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            var font = body
            if let hashes = text.firstIndex(where: { $0 != "#" }), hashes > text.startIndex,
               text[hashes] == " " {
                let level = text.distance(from: text.startIndex, to: hashes)
                font = .boldSystemFont(ofSize: max(13, 20 - CGFloat(level) * 2))
                text = String(text[text.index(after: hashes)...])
            } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
                text = "•  " + text.dropFirst(2)
            } else if text.hasPrefix("- [ ] ") || text.hasPrefix("- [x] ") {
                text = (text.hasPrefix("- [x] ") ? "☑︎  " : "☐  ") + text.dropFirst(6)
            }
            out.append(NSAttributedString(string: text + "\n",
                                          attributes: [.font: font, .foregroundColor: UIColor.black]))
        }
        return out
    }
}
