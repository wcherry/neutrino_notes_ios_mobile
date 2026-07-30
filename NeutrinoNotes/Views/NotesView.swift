import SwiftUI

// MARK: - NotesView

/// Root view for the Notes tab — browses the folders and Markdown documents stored
/// in Neutrino Drive, and owns navigation into folders and the note editor.
struct NotesView: View {

    // MARK: - Environment / State

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var noteContentService: NoteContentService
    @State private var selectedSection: NotesSection = .myNotes
    @State private var path = NavigationPath()

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
            browserView(parentID: nil)
                .navigationDestination(for: NoteItem.self) { destination in
                    if destination.type == .folder {
                        browserView(parentID: destination.id)
                    } else {
                        NoteEditorView(item: destination)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Section", selection: $selectedSection) {
                            ForEach(NotesSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                }
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
