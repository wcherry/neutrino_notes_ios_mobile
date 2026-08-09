import SwiftUI

// MARK: - NoteRouter

/// Opens a note from somewhere that cannot push one itself.
///
/// Tapping a `[[wiki link]]` happens inside `NoteEditorView`, which is a *pushed* screen: the
/// `NavigationPath` it lives on belongs to whichever tab pushed it, and there are four of those
/// (Notes, Recents, Favorites, Offline). Rather than hand the editor a path binding it would have
/// to be given four different ways, the editor hands the router a note and the enclosing stack —
/// the one that owns the path — picks it up.
///
/// One router per stack, so a link tapped in Recents pushes onto the Recents stack and nowhere
/// else. Deliberately *not* `DeepLinkRouter`: that one answers "did a Universal Link arrive, and is
/// the app ready for it yet", which an in-app tap has no business being mixed up with.
final class NoteRouter: ObservableObject {

    /// The note waiting to be pushed, if any.
    @Published private(set) var pending: NoteItem?

    init(pending: NoteItem? = nil) {
        self.pending = pending
    }

    func open(_ item: NoteItem) {
        pending = item
    }

    /// Returns the pending note and clears it, so a re-render doesn't push it twice.
    func consume() -> NoteItem? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Environment

private struct NoteRouterKey: EnvironmentKey {
    /// A router nobody is listening to. Means a view hosted outside a navigation stack — a preview,
    /// a test — can call `open` and have nothing happen, instead of crashing the way a missing
    /// `@EnvironmentObject` would.
    static let defaultValue = NoteRouter()
}

extension EnvironmentValues {
    var noteRouter: NoteRouter {
        get { self[NoteRouterKey.self] }
        set { self[NoteRouterKey.self] = newValue }
    }
}

// MARK: - Hosting

extension View {
    /// Wires `router` to `path`: whatever the router is handed gets pushed onto this stack.
    ///
    /// Apply inside the `NavigationStack` that owns `path`, and inject the same router into the
    /// environment so the screens on that stack can reach it.
    func noteRouting(_ router: NoteRouter, path: Binding<NavigationPath>) -> some View {
        modifier(NoteRoutingModifier(router: router, path: path))
    }
}

private struct NoteRoutingModifier: ViewModifier {
    @ObservedObject var router: NoteRouter
    @Binding var path: NavigationPath

    func body(content: Content) -> some View {
        content
            .environment(\.noteRouter, router)
            .onChange(of: router.pending?.id) { pendingID in
                guard pendingID != nil, let item = router.consume() else { return }
                path.append(item)
            }
    }
}
