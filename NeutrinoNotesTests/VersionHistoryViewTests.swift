import XCTest
import SwiftUI
import Sodium
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoNotes

/// Hosting tests for the version-history screens. Like ContentViewTests, the point is that
/// SwiftUI fatal-errors on a missing `@EnvironmentObject` the moment a body is evaluated, so
/// building each view for real is what proves the app's wiring is complete.
///
/// Both views are driven into a state that needs no server: the device is reported offline,
/// and no access token is present, so nothing here reaches the network.
@MainActor
final class VersionHistoryViewTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

    // MARK: - Helpers

    private func makeItem() -> NoteItem {
        NoteItem(id: "file-1", name: "Meeting Notes.md", type: .file, parentID: nil,
                 size: 512, modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    private func makeVersion(number: Int, label: String? = nil) throws -> NoteVersion {
        let json = """
        {"id":"ver-\(number)","fileId":"file-1","versionNumber":\(number),"sizeBytes":128,
         "label":\(label.map { "\"\($0)\"" } ?? "null"),
         "createdAt":"2026-07-30T14:25:36Z","isNamed":\(label != nil)}
        """
        return try NoteVersion.decoder.decode(NoteVersion.self, from: Data(json.utf8))
    }

    private func host(_ view: some View) {
        let hosting = UIHostingController(rootView: view)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Tests

    func test_versionHistoryView_builds() {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)

        host(
            VersionHistoryView(
                item: makeItem(),
                dek: sodium.secretStream.xchacha20poly1305.key(),
                currentText: "# Notes",
                onRestore: { _, _ in }
            )
            .environmentObject(VersionHistoryService())
            .environmentObject(monitor)
        )
    }

    func test_versionCompareView_builds() throws {
        let versions = [try makeVersion(number: 2, label: "Before the rewrite"), try makeVersion(number: 1)]

        host(
            VersionCompareView(
                item: makeItem(),
                dek: sodium.secretStream.xchacha20poly1305.key(),
                versions: versions,
                initialVersion: versions[0],
                currentText: "# Notes\n\nBody."
            )
            .environmentObject(VersionHistoryService())
        )
    }

    func test_saveVersionSheet_builds() {
        host(SaveVersionSheet { _ in })
    }

    // MARK: - Compare sources

    func test_compareSources_areDistinctAndTitled() throws {
        let version = try makeVersion(number: 4, label: "Draft")
        let current = VersionCompareView.Source.current
        let snapshot = VersionCompareView.Source.version(version)

        XCTAssertNotEqual(current, snapshot)
        XCTAssertEqual(current.title, "Current")
        XCTAssertEqual(snapshot.title, "v4")
        XCTAssertEqual(snapshot.longTitle, "Draft (v4)")
        // The id doubles as the cache key for a loaded side; it must not collide.
        XCTAssertNotEqual(current.id, snapshot.id)
        XCTAssertEqual(snapshot.id, version.id)
    }
}
