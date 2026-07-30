import XCTest
import SwiftUI
@testable import NeutrinoNotes

@MainActor
final class ContentViewTests: XCTestCase {

    func test_contentView_instantiates() {
        // ContentView reads `offlineStore` (Epic 9) directly in its body (the Offline tab
        // badge), so every environment object from the app's real wiring must be present here
        // too, exactly as in ContentView's own #Preview — otherwise SwiftUI fatal-errors on a
        // missing @EnvironmentObject as soon as `body` is evaluated below.
        let offlineDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let monitor = NetworkMonitor(autoStart: false)
        let content = NoteContentService()
        let offlineStore = OfflineStore(directory: offlineDirectory)

        let view = ContentView()
            .environmentObject(AuthService())
            .environmentObject(NotesDriveService())
            .environmentObject(content)
            .environmentObject(monitor)
            .environmentObject(offlineStore)
            .environmentObject(SyncEngine(store: offlineStore, monitor: monitor, content: content))
            .environmentObject(VersionHistoryService())
            .environmentObject(TagsService())
            .environmentObject(PinStore(defaults: UserDefaults(suiteName: "ContentViewTests.\(UUID().uuidString)")!))

        // `.environmentObject(...)` wraps ContentView in ModifiedContent, and SwiftUI fatal-errors
        // if `.body` is accessed directly on a ModifiedContent value (it isn't a plain composed
        // view). Hosting it forces SwiftUI to build the view hierarchy the same way UIKit would,
        // without reaching into `.body` ourselves.
        let hosting = UIHostingController(rootView: view)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)

        try? FileManager.default.removeItem(at: offlineDirectory)
    }
}
