import SwiftUI

// MARK: - NotesView

/// Root view for the Notes tab — browses the folders and Markdown documents stored
/// in Neutrino Drive, and owns navigation into folders and the note editor.
struct NotesView: View {

    // MARK: - Environment / State

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var noteContentService: NoteContentService
    @EnvironmentObject var tagsService: TagsService
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var selectedSection: NotesSection = .myNotes
    @State private var path = NavigationPath()
    @State private var linkError: String?

    /// Shared (Epic 22) and Tags (Epic 12) are feature-flagged, so the picker offers each only
    /// when its epic is enabled; My Notes and Trash have been there since Epic 4.
    private var sections: [NotesSection] {
        var sections: [NotesSection] = [.myNotes]
        if FeatureFlags.sharing { sections.append(.shared) }
        if FeatureFlags.organization { sections.append(.tags) }
        sections.append(.trash)
        return sections
    }

    // MARK: - Body

    var body: some View {
        if FeatureFlags.driveIntegration {
            featureFlagEnabledBody
        } else {
            NavigationStack {
                legacyPlaceholder
            }
        }
    }

    // MARK: - Feature-flagged Implementation

    private var featureFlagEnabledBody: some View {
        NavigationStack(path: $path) {
            sectionRoot
                .navigationDestination(for: NoteItem.self) { destination in
                    if destination.type == .folder {
                        browserView(parentID: destination.id)
                    } else {
                        NoteEditorView(item: destination)
                    }
                }
                .navigationDestination(for: NoteTag.self) { tag in
                    TaggedNotesView(tag: tag)
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Section", selection: $selectedSection) {
                            ForEach(sections) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)
                    }
                }
                // A folder (or tag) pushed under one section has no meaning under the next, so
                // switching sections returns to that section's root rather than leaving a stale
                // screen on top of the stack.
                .onChange(of: selectedSection) { _ in
                    path = NavigationPath()
                }
                .task(id: deepLinkRouter.pending?.id) {
                    await openPendingLink()
                }
                .alert("Couldn\u{2019}t Open Note", isPresented: Binding(
                    get: { linkError != nil },
                    set: { if !$0 { linkError = nil } }
                )) {
                    Button("OK") { linkError = nil }
                } message: {
                    Text(linkError ?? "")
                }
        }
    }

    // MARK: - Universal Links

    /// Opens the note an inbound `…/open/note/<id>` link named.
    ///
    /// The editor is pushed onto the current stack rather than switching to My Notes first:
    /// changing `selectedSection` resets `path` on the very next update, which would pop the note
    /// straight back off. Whichever section is showing is only a backdrop for the pushed editor.
    private func openPendingLink() async {
        guard FeatureFlags.appLinks, FeatureFlags.markdownEditor else { return }
        guard deepLinkRouter.pending != nil, let destination = deepLinkRouter.consume() else { return }

        // A link can name a note in a folder this session never opened, or one shared by another
        // account, so the cache is an optimisation and the server is the fallback.
        if let cached = notesDriveService.item(id: destination.fileID), cached.type == .file {
            path.append(cached)
            return
        }
        do {
            path.append(try await notesDriveService.fetchItem(id: destination.fileID))
        } catch {
            linkError = error.localizedDescription
        }
    }

    /// The root screen for the selected section. Tags browse tags rather than items, so that
    /// section has its own view instead of the item browser.
    @ViewBuilder
    private var sectionRoot: some View {
        if selectedSection == .tags {
            TagsView()
        } else {
            browserView(parentID: nil)
        }
    }

    private func browserView(parentID: String?) -> some View {
        NoteBrowserView(section: selectedSection, parentID: parentID) { newNote in
            path.append(newNote)
        }
        .environmentObject(notesDriveService)
        .environmentObject(noteContentService)
    }

    // MARK: - Legacy Placeholder

    private var legacyPlaceholder: some View {
        VStack {
            Spacer()
            Text("Notes")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Notes")
    }
}

// MARK: - Preview

#Preview {
    NotesView()
        .environmentObject(AuthService())
        .environmentObject(NotesDriveService())
        .environmentObject(NoteContentService())
        .environmentObject(VersionHistoryService())
        .environmentObject(DeepLinkRouter())
}
