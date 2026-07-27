import SwiftUI

@main
struct NeutrinoNotesApp: App {
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
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
