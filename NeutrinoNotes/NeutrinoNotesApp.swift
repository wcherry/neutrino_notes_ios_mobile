import SwiftUI

@main
struct NeutrinoNotesApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var notesDriveService = NotesDriveService()
    @StateObject private var noteContentService = NoteContentService()

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(notesDriveService)
                .environmentObject(noteContentService)
                .task {
                    notesDriveService.authService = authService
                    noteContentService.authService = authService
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
