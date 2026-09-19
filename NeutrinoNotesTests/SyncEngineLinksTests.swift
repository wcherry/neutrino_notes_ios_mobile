import XCTest
import Sodium
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoNotes

// MARK: - FakeLinkPublisher

@MainActor
private final class FakeLinkPublisher: NoteLinkPublishing {
    private(set) var calls: [(fileID: String, text: String)] = []
    var shouldFail = false

    func updateLinksIgnoringFailure(fileID: String, in text: String, force: Bool) async {
        calls.append((fileID, text))
        // The real one swallows its failures too; this mirrors that so a "failure" here can be
        // asserted not to affect the drain.
    }
}

// MARK: - SyncEngineLinksTests

/// Epic 20's half of the offline queue: a queued edit's `[[links]]` reach the server when — and
/// only when — its content does.
///
/// The editor deliberately skips the links call for an offline save, because the content it
/// describes hasn't been uploaded yet. This is the other end of that decision.
@MainActor
final class SyncEngineLinksTests: XCTestCase {

    private let sodium = Sodium()
    private var tempDirectory: URL!
    private var content: NoteContentService!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-links-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        content = NoteContentService()
        storeRealKeyPair()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        KeyringStore.shared.clear()
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    @MainActor
    private func storeRealKeyPair() -> Box.KeyPair {
        KeyringTestSupport.installKeyring()
    }

    private func seedNote(id: String = UUID().uuidString,
                          text: String,
                          serverModifiedAt: Date) throws -> (note: OfflineNote, dek: Bytes) {
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let ciphertext = try content.encrypt(text: text, dek: dek, xcss: xcss)
        try ciphertext.write(to: tempDirectory.appendingPathComponent("\(id).bin"))
        let note = OfflineNote(
            id: id, name: "Note.md", parentID: nil, mimeType: NoteItem.markdownMIME,
            sealedDEK: try content.sealDEK(dek).sealed, keyVersion: 1,
            serverModifiedAt: serverModifiedAt,
            cachedAt: Date(), sizeBytes: Int64(text.utf8.count), pendingEdit: nil, conflict: nil
        )
        return (note, dek)
    }

    private func makeStore(seeding notes: [OfflineNote]) throws -> OfflineStore {
        try JSONEncoder().encode(notes)
            .write(to: tempDirectory.appendingPathComponent("index.json"))
        let store = OfflineStore(directory: tempDirectory)
        store.noteContentService = content
        return store
    }

    private func makeEngine(store: OfflineStore,
                            content sync: any NoteSyncing,
                            links: any NoteLinkPublishing) -> SyncEngine {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(true)
        return SyncEngine(store: store, monitor: monitor, content: sync, links: links)
    }

    // MARK: - Tests

    func test_drain_publishesTheQueuedEditsLinksAfterItUploads() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base", serverModifiedAt: base)
        let store = try makeStore(seeding: [note])
        try store.writePendingEdit("see [[Meeting Notes]]", id: note.id, dek: dek)

        let sync = StubSyncing(serverModifiedAt: base, uploadedAt: base.addingTimeInterval(10))
        let links = FakeLinkPublisher()
        let engine = makeEngine(store: store, content: sync, links: links)

        await engine.syncNow()

        XCTAssertEqual(links.calls.count, 1)
        XCTAssertEqual(links.calls.first?.fileID, note.id)
        XCTAssertEqual(links.calls.first?.text, "see [[Meeting Notes]]",
                       "the graph must describe the text that was actually uploaded")
    }

    func test_drain_doesNotPublishLinksForAnEditItRefusedToUpload() async throws {
        // Server moved ahead of the edit's base version: the queued text is not on the server, so
        // describing its links would record edges for content nobody can see.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base", serverModifiedAt: base)
        let store = try makeStore(seeding: [note])
        try store.writePendingEdit("see [[Meeting Notes]]", id: note.id, dek: dek)

        let sync = StubSyncing(serverModifiedAt: base.addingTimeInterval(100),
                               uploadedAt: base.addingTimeInterval(200))
        let links = FakeLinkPublisher()
        let engine = makeEngine(store: store, content: sync, links: links)

        await engine.syncNow()

        XCTAssertEqual(sync.saveCount, 0)
        XCTAssertTrue(links.calls.isEmpty)
        XCTAssertNotNil(store.note(id: note.id)?.conflict)
    }

    func test_drain_withNoLinkPublisherAttached_stillUploads() async throws {
        // The queue predates the link graph and has to keep working without it.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (note, dek) = try seedNote(text: "base", serverModifiedAt: base)
        let store = try makeStore(seeding: [note])
        try store.writePendingEdit("edited", id: note.id, dek: dek)

        let sync = StubSyncing(serverModifiedAt: base, uploadedAt: base.addingTimeInterval(10))
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(true)
        let engine = SyncEngine(store: store, monitor: monitor, content: sync)

        await engine.syncNow()

        XCTAssertEqual(sync.saveCount, 1)
        XCTAssertNil(store.note(id: note.id)?.pendingEdit)
    }
}

// MARK: - StubSyncing

@MainActor
private final class StubSyncing: NoteSyncing {
    private let serverModifiedAt: Date
    private let uploadedAt: Date
    private(set) var saveCount = 0

    init(serverModifiedAt: Date, uploadedAt: Date) {
        self.serverModifiedAt = serverModifiedAt
        self.uploadedAt = uploadedAt
    }

    func fetchServerModifiedAt(for item: NoteItem) async throws -> Date? { serverModifiedAt }

    func saveContent(_ text: String, for item: NoteItem, dek: Bytes) async throws -> Date {
        saveCount += 1
        return uploadedAt
    }
}
