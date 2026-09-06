import SwiftUI
import NeutrinoCore

// MARK: - FavoritesView

/// Every starred folder and note, most recently starred first.
///
/// Favorites are Drive's `isStarred` flag, so a star set here shows up in the web app and vice
/// versa — unlike a pin, which is local to this device (`PinStore`).
struct FavoritesView: View {

    // MARK: - Environment

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var pinStore: PinStore

    // MARK: - Body

    var body: some View {
        if FeatureFlags.organization {
            favoritesBody
        } else {
            legacyPlaceholder
        }
    }

    // MARK: - Feature-flagged Implementation

    private var favoritesBody: some View {
        Group {
            if notesDriveService.isLoading && notesDriveService.starredItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notesDriveService.starredItems.isEmpty {
                emptyStateView
            } else {
                itemList
            }
        }
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: NoteItem.self) { item in
            if item.type == .folder {
                NoteBrowserView(section: .myNotes, parentID: item.id)
            } else {
                NoteEditorView(item: item)
            }
        }
        .task { await notesDriveService.loadStarred() }
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

    private var itemList: some View {
        List {
            ForEach(pinStore.sorted(notesDriveService.starredItems)) { item in
                NavigationLink(value: item) {
                    NoteRowView(item: item, isPinned: pinStore.isPinned(item.id))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        notesDriveService.setStarred(itemID: item.id, isStarred: false)
                    } label: {
                        Label("Remove", systemImage: "star.slash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    pinSwipeAction(for: item)
                }
                .contextMenu {
                    Button {
                        pinStore.togglePin(item.id)
                    } label: {
                        Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin to Top",
                              systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive) {
                        notesDriveService.setStarred(itemID: item.id, isStarred: false)
                    } label: {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await notesDriveService.loadStarred() }
    }

    private func pinSwipeAction(for item: NoteItem) -> some View {
        Button {
            pinStore.togglePin(item.id)
        } label: {
            Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin",
                  systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
        }
        .tint(.gray)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "star")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("No Favorites Yet")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Star a note or folder from the Notes tab to keep it here. Favorites are shared with the web app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable { await notesDriveService.loadStarred() }
    }

    // MARK: - Legacy Placeholder

    private var legacyPlaceholder: some View {
        VStack {
            Spacer()
            Text("Favorites")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Favorites")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FavoritesView()
            .environmentObject(NotesDriveService())
            .environmentObject(NoteContentService())
            .environmentObject(OfflineStore())
            .environmentObject(NetworkMonitor())
            .environmentObject(VersionHistoryService())
            .environmentObject(TagsService())
            .environmentObject(PinStore())
    }
}
