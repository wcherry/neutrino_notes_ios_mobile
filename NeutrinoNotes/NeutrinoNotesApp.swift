import SwiftUI

@main
struct NeutrinoNotesApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var notesDriveService = NotesDriveService()
    @StateObject private var noteContentService: NoteContentService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var offlineStore: OfflineStore
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var versionHistoryService = VersionHistoryService()
    @StateObject private var tagsService = TagsService()
    @StateObject private var pinStore = PinStore()
    @StateObject private var sharingService = SharingService()
    @StateObject private var appLockService = AppLockService()
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @StateObject private var linksService = LinksService()

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
            RootContentView(isSceneActive: scenePhase == .active)
                .environmentObject(authService)
                .environmentObject(notesDriveService)
                .environmentObject(noteContentService)
                .environmentObject(networkMonitor)
                .environmentObject(offlineStore)
                .environmentObject(syncEngine)
                .environmentObject(versionHistoryService)
                .environmentObject(tagsService)
                .environmentObject(pinStore)
                .environmentObject(sharingService)
                .environmentObject(appLockService)
                .environmentObject(deepLinkRouter)
                .environmentObject(linksService)
                .onOpenURL { url in
                    guard FeatureFlags.appLinks else { return }
                    deepLinkRouter.handle(url)
                }
                .task {
                    notesDriveService.authService = authService
                    notesDriveService.offlineStore = offlineStore
                    noteContentService.authService = authService
                    offlineStore.noteContentService = noteContentService
                    versionHistoryService.authService = authService
                    versionHistoryService.noteContentService = noteContentService
                    tagsService.authService = authService
                    sharingService.authService = authService
                    sharingService.noteContentService = noteContentService
                    linksService.authService = authService
                    // Epic 20: a queued offline edit updates the link graph when it finally
                    // uploads, not when it was typed.
                    syncEngine.attach(links: linksService)
                    syncEngine.start()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            // `.inactive` is deliberately not handled: it is the phase the biometric prompt puts
            // the scene in, so treating it as "the app went away" would restart the auto-lock
            // grace period on every unlock attempt. See `AppLockService`.
            switch newPhase {
            case .active:
                appLockService.didBecomeActive()
                syncEngine.requestSync()
            case .background:
                appLockService.didEnterBackground()
            default:
                break
            }
        }
    }
}

// MARK: - RootContentView

/// Wraps the authenticated/unauthenticated content and keeps the session alive across launches.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appLockService: AppLockService

    /// False while the scene is backgrounded *or* merely inactive — the privacy shield has to be
    /// up before iOS takes the app-switcher snapshot, and that happens during `.inactive`.
    let isSceneActive: Bool

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
                    // Only the signed-in content is locked. A lock screen in front of a login
                    // screen would protect nothing and could strand a user who cannot pass the
                    // owner check on a device they are only borrowing.
                    .appLocked(appLockService, isSceneActive: isSceneActive)
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
