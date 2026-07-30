import SwiftUI

@main
struct NeutrinoNotesApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var notesDriveService = NotesDriveService()
    @StateObject private var noteContentService: NoteContentService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var offlineStore: OfflineStore
    @StateObject private var syncEngine: SyncEngine

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let noteContentService = NoteContentService()
        let networkMonitor = NetworkMonitor()
        let offlineStore = OfflineStore()
        _noteContentService = StateObject(wrappedValue: noteContentService)
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _offlineStore = StateObject(wrappedValue: offlineStore)
        _syncEngine = StateObject(wrappedValue: SyncEngine(
            store: offlineStore, monitor: networkMonitor, content: noteContentService
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(notesDriveService)
                .environmentObject(noteContentService)
                .environmentObject(networkMonitor)
                .environmentObject(offlineStore)
                .environmentObject(syncEngine)
                .task {
                    notesDriveService.authService = authService
                    noteContentService.authService = authService
                    offlineStore.noteContentService = noteContentService
                    syncEngine.start()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                syncEngine.requestSync()
            }
        }
    }
}

// MARK: - RootContentView

/// Wraps the authenticated/unauthenticated content and keeps the session alive across launches.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
        .task {
            if authService.isAuthenticated {
                await authService.refreshTokenIfNeeded()
            }
        }
    }
}
