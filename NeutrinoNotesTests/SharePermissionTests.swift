import XCTest
@testable import NeutrinoNotes

/// Tests for the models the share sheet renders: what a role means, and how a permission list is
/// read off the wire and ordered.
final class SharePermissionTests: XCTestCase {

    // MARK: - Fixtures

    private func permission(_ id: String, name: String, role: ShareRole,
                            email: String = "someone@example.com") -> SharePermission {
        SharePermission(id: id, userID: "u-\(id)", userEmail: email, userName: name, role: role)
    }

    // MARK: - Roles

    func test_canEdit_isTrueOnlyForOwnerAndEditor() {
        XCTAssertTrue(ShareRole.owner.canEdit)
        XCTAssertTrue(ShareRole.editor.canEdit)
        // A commenter has no comment UI here (Epic 23) and Drive's autosave rejects them anyway.
        XCTAssertFalse(ShareRole.commenter.canEdit)
        XCTAssertFalse(ShareRole.viewer.canEdit)
    }

    func test_grantableRoles_excludeOwner() {
        // The server refuses a direct owner grant and requires transfer-ownership instead.
        XCTAssertEqual(ShareRole.grantable, [.editor, .commenter, .viewer])
    }

    func test_serverValue_isCaseInsensitive() {
        XCTAssertEqual(ShareRole(serverValue: "Editor"), .editor)
        XCTAssertEqual(ShareRole(serverValue: "OWNER"), .owner)
    }

    /// A role Drive adds later must not break the whole screen, and must not accidentally grant
    /// write access on the way through.
    func test_unknownServerValue_fallsBackToViewer() {
        XCTAssertEqual(ShareRole(serverValue: "organizer"), .viewer)
        XCTAssertFalse(ShareRole(serverValue: "organizer").canEdit)
    }

    // MARK: - Decoding

    func test_permission_decodesTheServerPayload() throws {
        let json = """
        {"id":"p1","resourceType":"file","resourceId":"f1","userId":"u1",
         "userEmail":"ada@example.com","userName":"Ada Lovelace","role":"editor",
         "grantedBy":"u0","createdAt":"2026-07-30 14:25:36"}
        """

        let permission = try JSONDecoder().decode(SharePermission.self, from: Data(json.utf8))

        XCTAssertEqual(permission.id, "p1")
        XCTAssertEqual(permission.userID, "u1")
        XCTAssertEqual(permission.userEmail, "ada@example.com")
        XCTAssertEqual(permission.role, .editor)
    }

    /// `createdAt` is stringified server-side with Rust's `to_string()` — a space instead of a `T`,
    /// which is not a shape `DriveDate` parses. Not decoding it is what keeps this payload
    /// readable; this test exists so re-adding the field can't quietly break the list.
    func test_permission_decodesEvenThoughCreatedAtIsNotAnISOTimestamp() throws {
        let json = """
        {"id":"p1","userId":"u1","userEmail":"ada@example.com","userName":"Ada",
         "role":"viewer","createdAt":"2026-07-30 14:25:36"}
        """

        XCTAssertNoThrow(try JSONDecoder().decode(SharePermission.self, from: Data(json.utf8)))
    }

    /// Guest permissions created by a share link carry an empty email and no name.
    func test_permission_toleratesMissingNameAndEmail() throws {
        let json = """
        {"id":"p1","userId":"u1","role":"viewer"}
        """

        let permission = try JSONDecoder().decode(SharePermission.self, from: Data(json.utf8))

        XCTAssertEqual(permission.displayName, "Unknown user")
        XCTAssertNil(permission.displayDetail)
    }

    // MARK: - Display

    func test_displayName_fallsBackToTheEmail() {
        let permission = SharePermission(id: "p1", userID: "u1", userEmail: "ada@example.com",
                                         userName: "", role: .viewer)

        XCTAssertEqual(permission.displayName, "ada@example.com")
        // The detail line would only repeat the title.
        XCTAssertNil(permission.displayDetail)
    }

    func test_displayDetail_isTheEmailWhenAThereIsAName() {
        let permission = permission("p1", name: "Ada", role: .viewer, email: "ada@example.com")

        XCTAssertEqual(permission.displayName, "Ada")
        XCTAssertEqual(permission.displayDetail, "ada@example.com")
    }

    // MARK: - Ordering

    func test_permissions_sortOwnerFirstThenByPrivilege() {
        let permissions = [
            permission("3", name: "Cleo", role: .viewer),
            permission("1", name: "Ada", role: .owner),
            permission("2", name: "Bob", role: .editor),
        ]

        let sorted = permissions.sorted(by: SharePermission.byRoleThenName)

        XCTAssertEqual(sorted.map(\.role), [.owner, .editor, .viewer])
    }

    func test_permissions_withTheSameRole_sortByName() {
        let permissions = [
            permission("2", name: "Zoe", role: .viewer),
            permission("1", name: "ada", role: .viewer),
        ]

        let sorted = permissions.sorted(by: SharePermission.byRoleThenName)

        XCTAssertEqual(sorted.map(\.userName), ["ada", "Zoe"])
    }

    // MARK: - Directory Users

    func test_directoryUser_displaysTheEmailWhenUnnamed() {
        let user = DirectoryUser(id: "u1", email: "ada@example.com", name: "")

        XCTAssertEqual(user.displayName, "ada@example.com")
        XCTAssertNil(user.displayDetail)
    }

    func test_directoryUser_decodesTheLookupPayload() throws {
        let json = #"{"id":"u1","email":"ada@example.com","name":"Ada Lovelace"}"#

        let user = try JSONDecoder().decode(DirectoryUser.self, from: Data(json.utf8))

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.displayName, "Ada Lovelace")
        XCTAssertEqual(user.displayDetail, "ada@example.com")
    }
}
