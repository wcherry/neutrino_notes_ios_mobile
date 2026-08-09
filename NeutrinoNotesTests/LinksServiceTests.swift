import XCTest
@testable import NeutrinoNotes

/// Tests for `LinksService` and the shapes it exchanges with Drive's link graph.
///
/// Same approach as `SharingServiceTests`: state is seeded through the DEBUG initializer, and the
/// network paths are exercised with no access token in the Keychain, which is what makes the
/// "never surfaces as a save failure" guarantee observable — every request fails in `authorized`
/// before it reaches the network.
@MainActor
final class LinksServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

    // MARK: - Fixtures

    private func link(_ id: String, _ title: String, _ fileType: String = "note") -> FileLink {
        FileLink(id: id, title: title, fileType: fileType)
    }

    // MARK: - Cache

    func test_backlinks_areEmptyForAFileNobodyHasLoaded() {
        XCTAssertTrue(LinksService().backlinks(for: "file-1").isEmpty)
    }

    func test_backlinks_readTheSeededCache() {
        let service = LinksService(backlinks: ["file-1": [link("a", "A.md")]])
        XCTAssertEqual(service.backlinks(for: "file-1").map(\.id), ["a"])
    }

    func test_forget_dropsOneFile() {
        let service = LinksService(backlinks: ["file-1": [link("a", "A.md")],
                                               "file-2": [link("b", "B.md")]])
        service.forget(fileID: "file-1")
        XCTAssertTrue(service.backlinks(for: "file-1").isEmpty)
        XCTAssertEqual(service.backlinks(for: "file-2").map(\.id), ["b"])
    }

    func test_forgetAll_dropsEverything() {
        let service = LinksService(backlinks: ["file-1": [link("a", "A.md")]])
        service.forgetAll()
        XCTAssertTrue(service.backlinksByFileID.isEmpty)
    }

    // MARK: - Failure Handling

    func test_loadBacklinks_withoutAToken_throwsNotAuthenticated() async {
        do {
            _ = try await LinksService().loadBacklinks(for: "file-1")
            XCTFail("expected the request to fail without an access token")
        } catch LinksError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("expected notAuthenticated, got \(error)")
        }
    }

    func test_updateLinksIgnoringFailure_swallowsTheFailure() async {
        // The note's content is already saved by the time this runs; a failed link update must not
        // be able to report anything, let alone turn into a visible save failure.
        let service = LinksService()
        await service.updateLinksIgnoringFailure(fileID: "file-1", in: "[[Something]]")
        XCTAssertTrue(service.backlinks(for: "file-1").isEmpty)
    }

    func test_updateLinksIgnoringFailure_aFailedSendIsNotRememberedAsSent() async {
        // Every request fails here (no token), so the dedupe must not conclude the titles are
        // already on the server — otherwise one flaky save would strand the graph until the titles
        // changed again.
        let service = LinksService()
        await service.updateLinksIgnoringFailure(fileID: "file-1", in: "[[A]]")
        await service.updateLinksIgnoringFailure(fileID: "file-1", in: "[[A]]")
        XCTAssertTrue(service.backlinks(for: "file-1").isEmpty)
    }

    // MARK: - Decoding

    func test_backlinksResponse_decodesTheServersCamelCaseShape() throws {
        let json = Data("""
        {"backlinks":[{"id":"f1","title":"Meeting Notes.md","fileType":"note"},
                      {"id":"f2","title":"Q3 Plan","fileType":"doc"}]}
        """.utf8)

        let response = try JSONDecoder().decode(BacklinksResponse.self, from: json)

        XCTAssertEqual(response.backlinks.map(\.id), ["f1", "f2"])
        XCTAssertEqual(response.backlinks[0].displayTitle, "Meeting Notes")
        XCTAssertTrue(response.backlinks[0].isNote)
        XCTAssertEqual(response.backlinks[1].kind, .doc)
        XCTAssertFalse(response.backlinks[1].isNote)
    }

    func test_fileLink_unknownFileType_hasNoKindAndIsNotANote() {
        // The server answers "file" for any MIME it has no mapping for; a backlink from one is
        // still worth showing, just not worth trying to open in a Neutrino app.
        let raw = link("f3", "budget.pdf", "file")
        XCTAssertNil(raw.kind)
        XCTAssertFalse(raw.isNote)
        XCTAssertEqual(raw.systemImage, "doc")
    }
}
