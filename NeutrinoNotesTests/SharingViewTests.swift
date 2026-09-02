import XCTest
import SwiftUI
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoNotes

/// Hosting tests for the Epic 22 screens. As in `OrganizationViewTests`, the point is that SwiftUI
/// fatal-errors on a missing `@EnvironmentObject` the moment a body is evaluated, so building each
/// view for real is what proves the app's wiring is complete.
///
/// No access token is present and the network monitor reports offline, so nothing here reaches the
/// server.
@MainActor
final class SharingViewTests: XCTestCase {

    private var offlineDirectory: URL!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: AuthService.accessTokenKey)
        offlineDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: offlineDirectory)
        offlineDirectory = nil
    }

    // MARK: - Fixtures

    private func ownedNote() -> NoteItem {
        NoteItem(id: "file-1", name: "Meeting Notes.md", type: .file, parentID: nil,
                 size: 512, modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    private func sharedNote() -> NoteItem {
        NoteItem(id: "file-2", name: "Their Note.md", type: .file, parentID: "their-folder",
                 size: 512, modifiedAt: Date(), isTrashed: false,
                 mimeType: NoteItem.markdownMIME, isStarred: false, isShared: true)
    }

    private func sharedFolder() -> NoteItem {
        NoteItem(id: "dir-1", name: "Their Folder", type: .folder, parentID: nil, size: nil,
                 modifiedAt: Date(), isTrashed: false, mimeType: nil,
                 isStarred: false, isShared: true)
    }

    private func sharingService() -> SharingService {
        let owner = SharePermission(id: "p0", userID: "me", userEmail: "me@example.com",
                                    userName: "Me", role: .owner)
        let editor = SharePermission(id: "p1", userID: "u1", userEmail: "ada@example.com",
                                     userName: "Ada Lovelace", role: .editor)
        let keyless = SharePermission(id: "p2", userID: "u2", userEmail: "bob@example.com",
                                      userName: "Bob", role: .viewer)
        return SharingService(
            permissions: [SharingService.resourceKey(for: ownedNote()): [owner, editor, keyless]],
            keyStatus: ["u1": .present, "u2": .missing]
        )
    }

    /// Every environment object the Notes-tab views read, matching the app's own wiring.
    private func host(_ view: some View, sharing: SharingService? = nil, shared: [NoteItem] = []) {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)
        let content = NoteContentService()
        let offlineStore = OfflineStore(directory: offlineDirectory)

        let wired = view
            .environmentObject(AuthService())
            .environmentObject(NotesDriveService(myNotes: [ownedNote()], shared: shared))
            .environmentObject(content)
            .environmentObject(monitor)
            .environmentObject(offlineStore)
            .environmentObject(SyncEngine(store: offlineStore, monitor: monitor, content: content))
            .environmentObject(VersionHistoryService())
            .environmentObject(TagsService())
            .environmentObject(PinStore(defaults: UserDefaults(suiteName: "SharingViewTests.\(UUID().uuidString)")!))
            .environmentObject(sharing ?? sharingService())

        let hosting = UIHostingController(rootView: wired)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Share Sheet

    func test_shareSheet_buildsForAnOwnedNote() {
        host(ShareSheet(item: ownedNote()))
    }

    func test_shareSheet_buildsForAFolder() {
        let folder = NoteItem(id: "dir-9", name: "Journal", type: .folder, parentID: nil,
                              size: nil, modifiedAt: Date(), isTrashed: false, mimeType: nil)

        host(ShareSheet(item: folder))
    }

    /// Nobody has been added yet and nothing has loaded — the empty path through the people list.
    func test_shareSheet_buildsWithNoPermissionsLoaded() {
        host(ShareSheet(item: ownedNote()), sharing: SharingService())
    }

    // MARK: - Browser

    func test_noteBrowserView_buildsInTheSharedSection() {
        host(NavigationStack { NoteBrowserView(section: .shared, parentID: nil) },
             shared: [sharedNote(), sharedFolder()])
    }

    func test_noteBrowserView_buildsTheEmptySharedSection() {
        host(NavigationStack { NoteBrowserView(section: .shared, parentID: nil) })
    }

    // MARK: - Editor

    /// A shared note opens read-only until the server reports a role, which it can't here — the
    /// monitor is offline — so this also covers the read-only editor body.
    func test_noteEditorView_buildsForASharedNote() {
        host(NavigationStack { NoteEditorView(item: sharedNote()) }, shared: [sharedNote()])
    }

    func test_notesView_buildsWithTheSharedSection() {
        host(NotesView())
    }

    // MARK: - Sections

    func test_notesSection_includesShared() {
        XCTAssertTrue(NotesSection.allCases.contains(.shared))
        XCTAssertEqual(NotesSection.shared.rawValue, "Shared")
        XCTAssertEqual(NotesSection.shared.iconName, "person.2")
    }
}
