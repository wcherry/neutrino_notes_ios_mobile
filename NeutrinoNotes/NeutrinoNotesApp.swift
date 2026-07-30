import SwiftUI

@main
struct NeutrinoNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var authService = AuthService()
    @StateObject private var notesDriveService = NotesDriveService()
    @StateObject private var noteContentService = NoteContentService()
    // SyncEngine.shared (not a fresh instance) so the environment object here and
    // AppDelegate's background BGProcessingTask handler observe/drive the exact same engine.
    @StateObject private var syncEngine = SyncEngine.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(notesDriveService)
                .environmentObject(noteContentService)
                .environmentObject(syncEngine)
                .task {
                    notesDriveService.authService = authService
                    noteContentService.authService = authService
                    notesDriveService.syncEngine = syncEngine
                    noteContentService.syncEngine = syncEngine
                    syncEngine.authService = authService
                    syncEngine.notesDriveService = notesDriveService
                    syncEngine.noteContentService = noteContentService

                    await runForegroundSync()

                    // Lightweight periodic in-app retry sweep while foregrounded — gated behind
                    // the feature flag; enqueueing mutations is never gated, only this extra
                    // sweep cadence is.
                    guard FeatureFlags.syncEngine else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 120_000_000_000) // 2 minutes
                        guard !Task.isCancelled else { break }
                        await runForegroundSync()
                    }
                }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                Task { await runForegroundSync() }
            case .background:
                AppDelegate.scheduleNext()
            default:
                break
            }
        }
    }

    /// Runs the shared sync routine and, on completion, makes sure a background attempt is
    /// scheduled too — so there's always a next background sync queued regardless of whether
    /// the user backgrounds the app immediately afterward.
    private func runForegroundSync() async {
        await syncEngine.runSync()
        AppDelegate.scheduleNext()
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
