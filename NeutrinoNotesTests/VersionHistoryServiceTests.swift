import XCTest
import Sodium
@testable import NeutrinoNotes

/// Tests for the assumptions version history rests on, exercised against the real libsodium
/// primitives rather than mocks — no network involved, mirroring NoteContentServiceTests.
///
/// The load-bearing assumption is that a note's DEK never rotates, so the DEK the editing
/// session already holds decrypts *every* snapshot of that note. If that ever stopped being
/// true, restore and compare would silently start failing, hence the round-trip tests below.
@MainActor
final class VersionHistoryServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        super.tearDown()
        KeyImportService.removeKeys()
    }

    // MARK: - Helpers

    /// A service wired to a real NoteContentService, the way the app wires it at launch.
    private func makeService() -> (VersionHistoryService, NoteContentService) {
        let content = NoteContentService()
        let service = VersionHistoryService()
        service.noteContentService = content
        return (service, content)
    }

    private func makeItem() -> NoteItem {
        NoteItem(id: "file-1", name: "Meeting Notes.md", type: .file, parentID: nil,
                 size: 0, modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    // MARK: - Snapshot round-trip

    func test_snapshotEncryptedWithTheNoteDEK_decryptsBackWithTheSameDEK() throws {
        let (_, content) = makeService()
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let markdown = "# Draft\n\n- point one\n- point two\n"

        // What saveVersion uploads…
        let ciphertext = try content.encrypt(
            text: markdown, dek: dek, xcss: sodium.secretStream.xchacha20poly1305
        )
        // …is what the download endpoint hands back, byte for byte.
        XCTAssertEqual(try content.decrypt(data: ciphertext, dek: dek), markdown)
    }

    func test_everySnapshotOfANote_decryptsWithTheOneSessionDEK() throws {
        let (_, content) = makeService()
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let revisions = ["v1 body", "v2 body, longer", "v3 body — with unicode ✓ and\nnewlines"]

        // Each save re-encrypts under the same DEK with a fresh secretstream header.
        let snapshots = try revisions.map {
            try content.encrypt(text: $0, dek: dek, xcss: sodium.secretStream.xchacha20poly1305)
        }
        XCTAssertEqual(try snapshots.map { try content.decrypt(data: $0, dek: dek) }, revisions)

        // Distinct headers mean two saves of identical text aren't byte-identical on the wire.
        let repeatA = try content.encrypt(text: "same", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)
        let repeatB = try content.encrypt(text: "same", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)
        XCTAssertNotEqual(repeatA, repeatB)
        XCTAssertEqual(try content.decrypt(data: repeatA, dek: dek),
                       try content.decrypt(data: repeatB, dek: dek))
    }

    func test_snapshotFromAnotherNote_doesNotDecrypt() throws {
        let (_, content) = makeService()
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let otherDEK = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(
            text: "secret", dek: dek, xcss: sodium.secretStream.xchacha20poly1305
        )

        XCTAssertThrowsError(try content.decrypt(data: ciphertext, dek: otherDEK))
    }

    func test_emptySnapshot_roundTrips() throws {
        // v1 of every note created by this app is the encrypted empty string.
        let (_, content) = makeService()
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(text: "", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)

        XCTAssertEqual(try content.decrypt(data: ciphertext, dek: dek), "")
    }

    // MARK: - Dependencies

    func test_withoutAContentService_versionOperationsFailCleanly() async {
        let service = VersionHistoryService()   // deliberately unwired
        let dek = sodium.secretStream.xchacha20poly1305.key()

        do {
            _ = try await service.saveVersion("body", for: makeItem(), dek: dek, label: nil)
            XCTFail("expected saveVersion to throw without a content service")
        } catch VersionHistoryError.noContentService {
            // Expected: it fails before touching the network, not after a doomed upload.
        } catch {
            XCTFail("expected .noContentService, got \(error)")
        }
    }

    // MARK: - Errors

    func test_errorsAreUserReadable() {
        let messages = [
            VersionHistoryError.notAuthenticated,
            .noContentService,
            .serverError(statusCode: 500),
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .decodingError(underlying: URLError(.cannotParseResponse)),
        ].map(\.localizedDescription)

        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertTrue(messages.contains { $0.contains("500") })
    }
}
