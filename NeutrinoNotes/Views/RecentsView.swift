import SwiftUI

// MARK: - RecentsView

/// The most recently modified notes, newest first.
///
/// This is the server's own `view=recent` listing, so it reflects edits made on any device — a
/// note changed in the web app appears here on the next refresh. Folders are never part of it:
/// the endpoint returns files only. Trashed notes are excluded server-side.
struct RecentsView: View {

    // MARK: - Environment

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var pinStore: PinStore

    // MARK: - Body

    var body: some View {
        if FeatureFlags.organization {
            recentsBody
        } else {
            legacyPlaceholder
        }
    }

    // MARK: - Feature-flagged Implementation

    private var recentsBody: some View {
        Group {
            if notesDriveService.isLoading && notesDriveService.recentItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notesDriveService.recentItems.isEmpty {
                emptyStateView
            } else {
                noteList
            }
        }
        .navigationTitle("Recents")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: NoteItem.self) { item in
            NoteEditorView(item: item)
        }
        .task { await notesDriveService.loadRecents() }
        .alert("Error", isPresented: Binding(
            get: { notesDriveService.error != nil },
            set: { if !$0 { notesDriveService.error = nil } }
        )) {
            Button("OK") { notesDriveService.error = nil }
        } message: {
            Text(notesDriveService.error ?? "")
        }
    }

    // MARK: - List

    private var noteList: some View {
        List {
            ForEach(pinStore.sorted(notesDriveService.recentItems)) { item in
                NavigationLink(value: item) {
                    NoteRowView(item: item, isPinned: pinStore.isPinned(item.id))
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        notesDriveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
                    } label: {
                        Label(item.isStarred ? "Unstar" : "Favorite",
                              systemImage: item.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)

                    Button {
                        pinStore.togglePin(item.id)
                    } label: {
                        Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin",
                              systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
                    }
                    .tint(.gray)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await notesDriveService.loadRecents() }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "clock")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Nothing Recent")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Notes you edit — here or in the web app — show up in this list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable { await notesDriveService.loadRecents() }
    }

    // MARK: - Legacy Placeholder

    private var legacyPlaceholder: some View {
        VStack {
            Spacer()
            Text("Recents")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Recents")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RecentsView()
            .environmentObject(NotesDriveService())
            .environmentObject(NoteContentService())
            .environmentObject(OfflineStore())
            .environmentObject(NetworkMonitor())
            .environmentObject(VersionHistoryService())
            .environmentObject(TagsService())
            .environmentObject(PinStore())
    }
}
