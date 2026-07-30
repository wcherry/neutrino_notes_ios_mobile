import SwiftUI

// MARK: - NotesView

/// Root view for the Notes tab — browses the folders and Markdown documents stored
/// in Neutrino Drive, and owns navigation into folders and the note editor.
struct NotesView: View {

    // MARK: - Environment / State

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var noteContentService: NoteContentService
    @EnvironmentObject var tagsService: TagsService
    @State private var selectedSection: NotesSection = .myNotes
    @State private var path = NavigationPath()

    /// Tags are an Epic 12 feature, so the picker offers them only when it is enabled.
    private var sections: [NotesSection] {
        FeatureFlags.organization ? NotesSection.allCases : [.myNotes, .trash]
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
                        .frame(maxWidth: 320)
                    }
                }
                // A folder (or tag) pushed under one section has no meaning under the next, so
                // switching sections returns to that section's root rather than leaving a stale
                // screen on top of the stack.
                .onChange(of: selectedSection) { _ in
                    path = NavigationPath()
                }
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
}
