import SwiftUI

struct ContentView: View {
    @EnvironmentObject var offlineStore: OfflineStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(0)

            NavigationStack {
                RecentsView()
            }
            .tabItem {
                Label("Recents", systemImage: "clock")
            }
            .tag(1)

            NavigationStack {
                FavoritesView()
            }
            .tabItem {
                Label("Favorites", systemImage: "star")
            }
            .tag(2)

            NavigationStack {
                OfflineView()
            }
            .tabItem {
                Label("Offline", systemImage: "arrow.down.circle")
            }
            .badge(offlineTabBadgeCount)
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(4)
        }
    }

    // MARK: - Offline Badge

    /// The number shown on the Offline tab — the count of notes with unsynced local edits.
    /// `.badge(0)` hides the badge, so this is a no-op when the flag is off or nothing is pending.
    private var offlineTabBadgeCount: Int {
        FeatureFlags.offlineEditing ? offlineStore.pendingCount : 0
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService())
        .environmentObject(NotesDriveService())
        .environmentObject(NoteContentService())
        .environmentObject(NetworkMonitor())
        .environmentObject(OfflineStore())
        .environmentObject(SyncEngine(store: OfflineStore(), monitor: NetworkMonitor(), content: NoteContentService()))
}
