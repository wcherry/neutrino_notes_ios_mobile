import SwiftUI

// MARK: - NotesView

/// Root view for the Notes tab — browses the folders and Markdown documents stored
/// in Neutrino Drive.
struct NotesView: View {

    // MARK: - Environment / State

    @EnvironmentObject var notesDriveService: NotesDriveService
    @State private var selectedSection: NotesSection = .myNotes

    // MARK: - Body

    var body: some View {
        if FeatureFlags.driveIntegration {
            featureFlagEnabledBody
        } else {
            legacyPlaceholder
        }
    }

    // MARK: - Feature-flagged Implementation

    private var featureFlagEnabledBody: some View {
        NoteBrowserView(section: selectedSection, parentID: nil)
            .environmentObject(notesDriveService)
            .navigationDestination(for: NoteItem.self) { destination in
                NoteBrowserView(section: selectedSection, parentID: destination.id)
                    .environmentObject(notesDriveService)
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
    NavigationStack {
        NotesView()
    }
    .environmentObject(NotesDriveService())
}
