import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoNotes

/// Tests for `SharingService`'s cache behaviour — the part that decides what the share sheet shows.
/// State is seeded through the DEBUG initializer; the optimistic mutations fire a background
/// request that fails without an access token, which is exactly what makes the rollback paths
/// observable.
@MainActor
final class SharingServiceTests: XCTestCase {

    // MARK: - Lifecycle

    /// Guarantees the "no token" precondition: without one, every request fails in `authorized`
    /// before anything reaches the network.
    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

    // MARK: - Fixtures

    private func note(id: String = "file-1") -> NoteItem {
        NoteItem(id: id, name: "Meeting Notes.md", type: .file, parentID: nil, size: 512,
                 modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
    }

    private func folder(id: String = "dir-1") -> NoteItem {
        NoteItem(id: id, name: "Journal", type: .folder, parentID: nil, size: nil,
                 modifiedAt: Date(), isTrashed: false, mimeType: nil)
    }

    private func permission(_ id: String, role: ShareRole, userID: String? = nil) -> SharePermission {
        SharePermission(id: id, userID: userID ?? "u-\(id)", userEmail: "\(id)@example.com",
                        userName: "User \(id)", role: role)
    }

    private func seeded(_ permissions: [SharePermission], on item: NoteItem) -> SharingService {
        SharingService(permissions: [SharingService.resourceKey(for: item): permissions])
    }

    // MARK: - Resource Keys

    func test_resourcePath_dependsOnTheItemType() {
        XCTAssertEqual(SharingService.resourcePath(for: note()), "files")
        XCTAssertEqual(SharingService.resourcePath(for: folder()), "folders")
    }

    /// A file and a folder could carry the same id, so the cache key has to be type-qualified.
    func test_resourceKey_distinguishesAFileFromAFolderWithTheSameID() {
        let file = NoteItem(id: "same", name: "n", type: .file, parentID: nil, size: nil,
                            modifiedAt: Date(), isTrashed: false, mimeType: NoteItem.markdownMIME)
        let folder = NoteItem(id: "same", name: "n", type: .folder, parentID: nil, size: nil,
                              modifiedAt: Date(), isTrashed: false, mimeType: nil)

        XCTAssertNotEqual(SharingService.resourceKey(for: file), SharingService.resourceKey(for: folder))
    }

    // MARK: - Queries

    func test_seededPermissions_areSortedOwnerFirst() {
        let item = note()
        let sut = seeded([permission("b", role: .viewer), permission("a", role: .owner)], on: item)

        XCTAssertEqual(sut.permissions(for: item).map(\.role), [.owner, .viewer])
    }

    func test_permissions_forAnUnknownItem_isEmptyRatherThanNil() {
        let sut = SharingService()

        XCTAssertEqual(sut.permissions(for: note()), [])
    }

    func test_collaborators_excludeTheOwner() {
        let item = note()
        let sut = seeded([permission("a", role: .owner), permission("b", role: .editor)], on: item)

        XCTAssertEqual(sut.collaborators(for: item).map(\.role), [.editor])
    }

    /// Only an owner can read a permission list at all, so the owner row *is* this account — which
    /// is how the sheet refuses to share with the signed-in user without an `/auth/me` round trip.
    func test_ownerUserID_isTakenFromTheOwnerRow() {
        let item = note()
        let sut = seeded([permission("a", role: .owner, userID: "me"),
                          permission("b", role: .editor)], on: item)

        XCTAssertEqual(sut.ownerUserID(for: item), "me")
    }

    func test_ownerUserID_isNilBeforeThePermissionsAreLoaded() {
        XCTAssertNil(SharingService().ownerUserID(for: note()))
    }

    // MARK: - Sharing With Yourself

    func test_share_withTheOwner_isRejectedWithoutTouchingTheNetwork() async {
        let item = note()
        let sut = seeded([permission("a", role: .owner, userID: "me")], on: item)
        let me = DirectoryUser(id: "me", email: "me@example.com", name: "Me")

        do {
            _ = try await sut.share(item, with: me, role: .editor)
            XCTFail("Expected sharing with yourself to be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           SharingError.cannotShareWithYourself.localizedDescription)
        }
    }

    // MARK: - Role Changes

    func test_updateRole_changesTheCachedRoleImmediately() {
        let item = note()
        let editor = permission("b", role: .editor)
        let sut = seeded([permission("a", role: .owner), editor], on: item)

        sut.updateRole(of: editor, on: item, to: .viewer)

        XCTAssertEqual(sut.collaborators(for: item).map(\.role), [.viewer])
    }

    func test_updateRole_toTheSameRole_isANoOp() {
        let item = note()
        let editor = permission("b", role: .editor)
        let sut = seeded([editor], on: item)

        sut.updateRole(of: editor, on: item, to: .editor)

        XCTAssertEqual(sut.permissions(for: item).map(\.role), [.editor])
    }

    /// The write fails without a token, so the optimistic change has to come back.
    func test_updateRole_rollsBackWhenTheServerRefuses() async throws {
        let item = note()
        let editor = permission("b", role: .editor)
        let sut = seeded([editor], on: item)

        sut.updateRole(of: editor, on: item, to: .viewer)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.permissions(for: item).map(\.role), [.editor])
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Revoking

    func test_revoke_removesThePersonImmediately() {
        let item = note()
        let viewer = permission("b", role: .viewer)
        let sut = seeded([permission("a", role: .owner), viewer], on: item)

        sut.revoke(viewer, on: item)

        XCTAssertEqual(sut.permissions(for: item).map(\.role), [.owner])
    }

    func test_revoke_rollsBackWhenTheServerRefuses() async throws {
        let item = note()
        let viewer = permission("b", role: .viewer)
        let sut = seeded([permission("a", role: .owner), viewer], on: item)

        sut.revoke(viewer, on: item)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(Set(sut.permissions(for: item).map(\.userID)), ["u-a", "u-b"])
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Key Status

    func test_keyStatus_isUnknownUntilItHasBeenLookedUp() {
        XCTAssertNil(SharingService().keyStatus(for: "u1"))
    }

    /// A person with no registered public key is the one case a permission cannot fix: nothing can
    /// be sealed for them, so the sheet has to say so.
    func test_seededKeyStatus_isReported() {
        let sut = SharingService(keyStatus: ["u1": .missing, "u2": .present])

        XCTAssertEqual(sut.keyStatus(for: "u1"), .missing)
        XCTAssertEqual(sut.keyStatus(for: "u2"), .present)
    }

    func test_shareKey_withoutAContentService_reportsThatEncryptionIsUnavailable() async {
        let sut = SharingService()

        do {
            _ = try await sut.shareKey(fileID: "file-1", with: "u1")
            XCTFail("Expected the missing content service to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           SharingError.noContentService.localizedDescription)
        }
    }

    // MARK: - Share Results

    func test_shareResult_summarizesAMissingRecipientKey() {
        var result = SharingService.ShareResult(notesShared: 1)
        result.recipientHasNoKey = true

        XCTAssertEqual(result.summary?.contains("can't read it"), true)
    }

    /// A folder share is allowed to partially succeed, and has to say so rather than claim success.
    func test_shareResult_summarizesPartialFolderFailure() {
        let result = SharingService.ShareResult(notesShared: 12, notesFailed: 2)

        XCTAssertEqual(result.summary, "Shared 12 of 14 notes — the rest couldn't be shared.")
    }

    func test_shareResult_forASingleNote_hasNothingWorthSaying() {
        let result = SharingService.ShareResult(notesShared: 1, keysDelivered: 1)

        XCTAssertNil(result.summary)
    }

    // MARK: - Directory

    /// A one-character query would ask the directory for most of the organization; the sheet's
    /// prompt says "keep typing" instead.
    func test_searchUsers_belowTwoCharacters_makesNoRequest() async throws {
        let sut = SharingService()

        let results = try await sut.searchUsers(matching: " a ")

        XCTAssertEqual(results, [])
    }

    func test_searchUsers_withAQuery_requiresAuthentication() async {
        let sut = SharingService()

        do {
            _ = try await sut.searchUsers(matching: "ada")
            XCTFail("Expected the unauthenticated search to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           SharingError.notAuthenticated.localizedDescription)
        }
    }

    // MARK: - Errors

    func test_notOwnerError_explainsWhoMayShare() {
        XCTAssertEqual(SharingError.notOwner.errorDescription,
                       "Only the owner can manage sharing for this item.")
    }

    func test_userNotFoundError_namesTheAddress() {
        XCTAssertEqual(SharingError.userNotFound("ada@example.com").errorDescription,
                       "No Neutrino account found for \u{201C}ada@example.com\u{201D}.")
    }

    func test_serverErrorDescription_includesTheStatusCode() {
        XCTAssertEqual(SharingError.serverError(statusCode: 403).errorDescription, "Server error (403).")
    }
}
