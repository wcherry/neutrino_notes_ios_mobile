import SwiftUI
import UIKit

// MARK: - MarkdownTextEditor

/// The note editor's plain-text editing surface, backed by a `UITextView`.
///
/// SwiftUI's `TextEditor` is deliberately not used: it reports neither the caret nor the keystroke
/// behind an edit, and writing a modified string back through its binding drops the caret at the
/// end of the document. Both of the editor's typing aids need all three — checklist continuation
/// has to see that Return was pressed and leave the caret after the marker it inserted, and the `/`
/// format menu has to know where on screen the caret it belongs to is.
struct MarkdownTextEditor: UIViewRepresentable {

    @Binding var text: String
    var isEditable: Bool
    /// Lets the owning view drive the text view for what surrounds it: undo, redo, and find &
    /// replace in the navigation bar, and the `/` format menu drawn over the text.
    let controller: MarkdownTextEditorController

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.font = Self.font
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        // Without these the text view asks to be exactly as tall as its text, and a short note
        // leaves the status bar floating in the middle of the screen.
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        controller.attach(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        // Only for changes from outside the editor — a load, or a restored version. Assigning the
        // same string would still reset the caret to the end of the document mid-sentence.
        if textView.text != text {
            textView.text = text
            // The text under any open menu has just been replaced wholesale, so the command that
            // opened it is gone too.
            controller.endSlashCommand()
            controller.endWikiLink()
        }
        textView.isEditable = isEditable
        textView.textColor = isEditable ? .label : .secondaryLabel
        controller.attach(textView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, controller: controller)
    }

    /// Monospaced, matching the rest of the editor, and scaled for the reader's text size.
    private static var font: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: UIFont.labelFontSize, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {

        var text: Binding<String>
        let controller: MarkdownTextEditorController

        init(text: Binding<String>, controller: MarkdownTextEditorController) {
            self.text = text
            self.controller = controller
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            refreshSlashCommand(in: textView, canOpen: true)
            refreshWikiLink(in: textView, canOpen: true)
        }

        /// A moved caret can follow a `/` command or a `[[` link it is still typing, but never
        /// starts one — so tapping into a line that happens to begin with a slash, or landing
        /// inside a link written earlier, doesn't spring a menu open.
        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshSlashCommand(in: textView, canOpen: false)
            refreshWikiLink(in: textView, canOpen: false)
        }

        /// Keeps whichever menu is open with its caret when the note scrolls under it.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = controller.textView else { return }
            let caret = caretRect(in: textView)
            if controller.slashCommand != nil { controller.moveSlashCommandMenu(to: caret) }
            if controller.wikiLink != nil { controller.moveWikiLinkMenu(to: caret) }
        }

        /// Intercepts Return so a checklist can carry itself on to the next line. Every other
        /// keystroke is handled by the text view as usual.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n",
                  let action = MarkdownChecklist.returnAction(in: textView.text as NSString, replacing: range)
            else { return true }

            switch action {
            case .continueList(let insertion):
                replace(range, with: insertion, in: textView)
            case .endList(let markerRange):
                replace(markerRange, with: "", in: textView)
            }
            return false
        }

        // MARK: - Slash Commands

        /// Opens, narrows, or closes the format menu after the text or the caret has moved.
        ///
        /// `canOpen` is the difference between the two: typing may start a menu, moving the caret
        /// may only stay with one it is already on.
        func refreshSlashCommand(in textView: UITextView, canOpen: Bool) {
            let openCommand = controller.slashCommand
            guard canOpen || openCommand != nil else { return }

            let caret = textView.selectedRange
            guard caret.length == 0,
                  let token = MarkdownSlashCommand.token(in: textView.text as NSString, caret: caret.location),
                  canOpen || token.range.location == openCommand?.range.location
            else {
                controller.endSlashCommand()
                return
            }
            controller.showSlashCommandMenu(for: token, at: caretRect(in: textView))
        }

        // MARK: - Wiki Links

        /// Opens, narrows, or closes the note picker after the text or the caret has moved.
        ///
        /// Mirrors `refreshSlashCommand`; the difference is only which token it looks for. A link
        /// the user finished typing by hand (`[[Done]]`) yields no token, so the menu closes on the
        /// closing brackets rather than lingering.
        func refreshWikiLink(in textView: UITextView, canOpen: Bool) {
            guard FeatureFlags.noteLinks else { return }
            let openLink = controller.wikiLink
            guard canOpen || openLink != nil else { return }

            let caret = textView.selectedRange
            guard caret.length == 0,
                  let token = WikiLink.token(in: textView.text as NSString, caret: caret.location),
                  canOpen || token.range.location == openLink?.range.location
            else {
                controller.endWikiLink()
                return
            }
            controller.showWikiLinkMenu(for: token, at: caretRect(in: textView))
        }

        /// Completes the half-typed link with `title`, closing the brackets and leaving the caret
        /// after them so typing carries straight on.
        func completeWikiLink(with title: String) {
            guard let textView = controller.textView, let link = controller.wikiLink else { return }

            let completed = "[[\(title)]]"
            replace(link.range, with: completed, in: textView)
            if let caret = textView.position(from: textView.beginningOfDocument,
                                             offset: link.range.location + (completed as NSString).length) {
                textView.selectedTextRange = textView.textRange(from: caret, to: caret)
            }
            controller.endWikiLink()
        }

        // MARK: - Slash Commands (continued)

        /// Writes a chosen format over the `/` command that opened the menu, and leaves the caret
        /// where the user's own text goes — inside `**|**`, after `# `.
        func apply(_ format: MarkdownFormat) {
            guard let textView = controller.textView, let command = controller.slashCommand else { return }

            replace(command.range, with: format.snippet, in: textView)
            if let caret = textView.position(from: textView.beginningOfDocument,
                                             offset: command.range.location + format.caretOffset) {
                textView.selectedTextRange = textView.textRange(from: caret, to: caret)
            }
            controller.endSlashCommand()
        }

        /// The caret's line in the text view's own coordinates, which are the coordinates the menu
        /// is positioned in. `.zero` while the text view has no selection to draw a caret for.
        private func caretRect(in textView: UITextView) -> CGRect {
            guard let selection = textView.selectedTextRange else { return .zero }
            let rect = textView.caretRect(for: selection.end)
            guard !rect.isNull, !rect.isInfinite else { return .zero }
            return rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
        }

        // MARK: - Editing

        /// Applies an edit the way typing does, through `UITextInput`: the caret lands after the
        /// replacement, and the change joins the text view's undo stack — so Undo takes back an
        /// auto-inserted marker like any other keystroke.
        private func replace(_ range: NSRange, with string: String, in textView: UITextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(textRange, withText: string)
            text.wrappedValue = textView.text
        }
    }
}

// MARK: - MarkdownTextEditorController

/// A handle on the editor's text view for what happens around it: the navigation bar's undo, redo,
/// and find & replace, and the `/` format menu, which SwiftUI draws over the text. Held by the
/// owning view so all of those have something to talk to.
final class MarkdownTextEditorController: ObservableObject {

    /// The `/` command being typed, or `nil` when no menu should be on screen.
    @Published private(set) var slashCommand: SlashCommand?

    /// The `[[` link being typed, or `nil` when no note picker should be on screen.
    @Published private(set) var wikiLink: WikiLinkInProgress?

    /// Where to put the format menu, and what to put in it.
    struct SlashCommand: Equatable {
        /// What has been typed after the slash. The menu filters itself on this.
        let query: String
        /// The caret's line, in the editor's own coordinates, for the menu to sit next to.
        let caretRect: CGRect
        /// The `/query` text a chosen format replaces.
        fileprivate let range: NSRange
    }

    /// Where to put the note picker, and what to filter it by.
    struct WikiLinkInProgress: Equatable {
        /// What has been typed since the `[[`.
        let query: String
        let caretRect: CGRect
        /// The `[[query` text a chosen note replaces, brackets included.
        fileprivate let range: NSRange
    }

    /// Weak, and `nil` whenever the editor isn't on screen — in Preview mode, for instance, where
    /// the navigation bar's editing actions correctly appear disabled.
    fileprivate weak var textView: UITextView?
    fileprivate weak var coordinator: MarkdownTextEditor.Coordinator?

    /// Points the controller at the editor it drives. Called as the text view is made and on every
    /// SwiftUI update, since a representable's view may be rebuilt under it.
    func attach(_ textView: UITextView, coordinator: MarkdownTextEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    /// The text view's own undo manager: the one typing registers with while it is first responder,
    /// which is not the same object as SwiftUI's `\.undoManager`.
    var undoManager: UndoManager? {
        textView?.undoManager
    }

    func undo() {
        textView?.undoManager?.undo()
    }

    func redo() {
        textView?.undoManager?.redo()
    }

    func presentFindNavigator(showingReplace: Bool) {
        textView?.findInteraction?.presentFindNavigator(showingReplace: showingReplace)
    }

    // MARK: - Slash Commands

    /// Writes the chosen format over the `/` command that opened the menu.
    func apply(_ format: MarkdownFormat) {
        coordinator?.apply(format)
    }

    fileprivate func showSlashCommandMenu(for token: MarkdownSlashCommand.Token, at caretRect: CGRect) {
        let command = SlashCommand(query: token.query, caretRect: caretRect, range: token.range)
        guard command != slashCommand else { return }
        slashCommand = command
    }

    fileprivate func moveSlashCommandMenu(to caretRect: CGRect) {
        guard let slashCommand, slashCommand.caretRect != caretRect else { return }
        self.slashCommand = SlashCommand(query: slashCommand.query,
                                         caretRect: caretRect,
                                         range: slashCommand.range)
    }

    fileprivate func endSlashCommand() {
        guard slashCommand != nil else { return }
        slashCommand = nil
    }

    // MARK: - Wiki Links

    /// Writes `[[title]]` over the half-typed link that opened the picker.
    func completeWikiLink(with title: String) {
        coordinator?.completeWikiLink(with: title)
    }

    fileprivate func showWikiLinkMenu(for token: WikiLink.Token, at caretRect: CGRect) {
        let link = WikiLinkInProgress(query: token.query, caretRect: caretRect, range: token.range)
        guard link != wikiLink else { return }
        wikiLink = link
    }

    fileprivate func moveWikiLinkMenu(to caretRect: CGRect) {
        guard let wikiLink, wikiLink.caretRect != caretRect else { return }
        self.wikiLink = WikiLinkInProgress(query: wikiLink.query,
                                           caretRect: caretRect,
                                           range: wikiLink.range)
    }

    fileprivate func endWikiLink() {
        guard wikiLink != nil else { return }
        wikiLink = nil
    }
}
