import SwiftUI

struct ContentView: View {
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
}

#Preview {
    ContentView()
        .environmentObject(AuthService())
        .environmentObject(NotesDriveService())
        .environmentObject(NoteContentService())
        .environmentObject(SyncEngine())
}
