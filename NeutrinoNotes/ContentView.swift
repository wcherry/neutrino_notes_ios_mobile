import SwiftUI
import NeutrinoCore
import NeutrinoAuth

struct ContentView: View {
    @EnvironmentObject var offlineStore: OfflineStore
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var selectedTab = 0

    // Epic 20: each tab's stack owns its own path, so each needs its own router to push a
    // `[[wiki link]]` onto. A single shared one would push the same note onto all four.
    @State private var recentsPath = NavigationPath()
    @State private var favoritesPath = NavigationPath()
    @State private var offlinePath = NavigationPath()
    @StateObject private var recentsRouter = NoteRouter()
    @StateObject private var favoritesRouter = NoteRouter()
    @StateObject private var offlineRouter = NoteRouter()

    var body: some View {
        TabView(selection: $selectedTab) {
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(0)

            NavigationStack(path: $recentsPath) {
                RecentsView()
                    .noteRouting(recentsRouter, path: $recentsPath)
            }
            .tabItem {
                Label("Recents", systemImage: "clock")
            }
            .tag(1)

            NavigationStack(path: $favoritesPath) {
                FavoritesView()
                    .noteRouting(favoritesRouter, path: $favoritesPath)
            }
            .tabItem {
                Label("Favorites", systemImage: "star")
            }
            .tag(2)

            NavigationStack(path: $offlinePath) {
                OfflineView()
                    .noteRouting(offlineRouter, path: $offlinePath)
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
        // A note link has to land on the Notes tab whatever the user was last looking at —
        // NotesView owns the navigation stack the editor is pushed onto, and it only consumes the
        // pending link once it is on screen.
        .onChange(of: deepLinkRouter.pending?.id) { pendingID in
            if pendingID != nil { selectedTab = 0 }
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
        .environmentObject(VersionHistoryService())
        .environmentObject(TagsService())
        .environmentObject(PinStore())
        .environmentObject(SharingService())
        .environmentObject(AppLockService())
        .environmentObject(DeepLinkRouter())
}
