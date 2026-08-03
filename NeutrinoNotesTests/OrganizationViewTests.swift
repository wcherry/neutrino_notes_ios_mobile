import XCTest
import SwiftUI
@testable import NeutrinoNotes

/// Hosting tests for the Epic 12 screens. As in `VersionHistoryViewTests`, the point is that
/// SwiftUI fatal-errors on a missing `@EnvironmentObject` the moment a body is evaluated, so
/// building each view for real is what proves the app's wiring is complete.
///
/// No access token is present and the network monitor reports offline, so nothing here reaches
/// the server.
@MainActor
final class OrganizationViewTests: XCTestCase {

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

    // MARK: - Helpers

    private func makeItem() -> NoteItem {
        NoteItem(id: "file-1", name: "Meeting Notes.md", type: .file, parentID: nil,
                 size: 512, modifiedAt: Date(), isTrashed: false,
                 mimeType: NoteItem.markdownMIME, isStarred: true)
    }

    private func makeTag() -> NoteTag {
        NoteTag(id: "tag-1", name: "Work", createdAt: Date())
    }

    /// Every environment object the Notes-tab views read, matching the app's own wiring.
    private func host(_ view: some View, tagsService: TagsService? = nil) {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)
        let content = NoteContentService()
        let offlineStore = OfflineStore(directory: offlineDirectory)

        let wired = view
            .environmentObject(AuthService())
            .environmentObject(NotesDriveService(myNotes: [makeItem()],
                                                 starred: [makeItem()],
                                                 recents: [makeItem()]))
            .environmentObject(content)
            .environmentObject(monitor)
            .environmentObject(offlineStore)
            .environmentObject(SyncEngine(store: offlineStore, monitor: monitor, content: content))
            .environmentObject(VersionHistoryService())
            .environmentObject(tagsService ?? TagsService(tags: [makeTag()]))
            .environmentObject(PinStore(defaults: UserDefaults(suiteName: "OrganizationViewTests.\(UUID().uuidString)")!))

        let hosting = UIHostingController(rootView: wired)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Tests

    func test_favoritesView_builds() {
        host(NavigationStack { FavoritesView() })
    }

    func test_recentsView_builds() {
        host(NavigationStack { RecentsView() })
    }

    func test_tagsView_builds() {
        host(NavigationStack { TagsView() })
    }

    func test_taggedNotesView_builds() {
        host(NavigationStack { TaggedNotesView(tag: makeTag()) })
    }

    func test_tagPickerSheet_builds() {
        host(TagPickerSheet(item: makeItem()))
    }

    func test_tagNameSheet_builds() {
        host(TagNameSheet(title: "New Tag", initialName: "") { _ in })
    }

    /// The editor reads `TagsService` for its tag bar, so it now needs that environment object as
    /// well as the six it already took.
    func test_noteEditorView_buildsWithTaggedNote() {
        let tagged = TagsService(tags: [makeTag()], tagsByFileID: ["file-1": [makeTag()]])

        host(NavigationStack { NoteEditorView(item: makeItem()) }, tagsService: tagged)
    }

    func test_noteBrowserView_buildsWithOrganizationActions() {
        host(NavigationStack { NoteBrowserView(section: .myNotes, parentID: nil) })
    }

    // MARK: - Sections

    func test_notesSection_includesTags() {
        XCTAssertTrue(NotesSection.allCases.contains(.tags))
        XCTAssertEqual(NotesSection.tags.rawValue, "Tags")
        XCTAssertEqual(NotesSection.tags.iconName, "tag")
    }
}
