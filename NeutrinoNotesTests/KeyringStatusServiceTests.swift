import XCTest
import NeutrinoAuth
import NeutrinoCore
@testable import NeutrinoNotes

// MARK: - KeyringStatusServiceTests
//
// What the app asks at sign-in, and what it does with the answer: `.missing` and
// `.belongsToAnotherAccount` put the restore sheet in front of the user, `.present` leaves them
// alone. Both mistakes are visible — a spurious prompt asks somebody who is perfectly set up to go
// and find their recovery kit, and a missed one lets them sign in, browse, and discover the problem
// only when the first note refuses to open.
//
// Unlike the vault-based apps there is no network here at all: the keyring is created on a client
// and never transmitted, so every branch below is a Keychain read plus a JWT claim.

@MainActor
final class KeyringStatusServiceTests: XCTestCase {

    /// `{"alg":"none","typ":"JWT"}.{"sub":"test-user"}.` — a real JWT shape rather than an opaque
    /// string, because `currentUserID()` decodes the `sub` claim out of it. "test-user" is
    /// `KeyringTestSupport.testUserID`, so a keyring installed by that helper belongs to this token.
    private static let tokenForTestUser =
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ0ZXN0LXVzZXIifQ."
    /// The same, for a *different* account: `{"sub":"other-user"}`.
    private static let tokenForOtherUser =
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJvdGhlci11c2VyIn0."

    /// Held by the test, not just handed to the service: `KeyringStatusService.authService` is a
    /// `weak var` — the app's copy is owned by a `@StateObject` — so a locally-created one would be
    /// deallocated before `refresh()` ran and every account check would silently take the
    /// "account unknown" path.
    private var authService: AuthService?

    override func setUp() {
        super.setUp()
        KeyringTestSupport.clear()
        KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

    override func tearDown() {
        authService = nil
        KeyringTestSupport.clear()
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// An auth service whose `currentUserID()` resolves to `sub` without any network call — the
    /// token is decoded locally, and only an undecodable one falls back to `GET /auth/me`.
    private func signedIn(as token: String) -> AuthService {
        KeychainService.save(token, forKey: AuthService.accessTokenKey)
        let service = AuthService()
        authService = service
        return service
    }

    // MARK: - No keyring on this device

    func testStatusIsMissingWhenThisDeviceHoldsNoKeyring() async {
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))

        await sut.refresh()

        // The case the whole feature exists for: signed in, and unable to read a single note.
        XCTAssertEqual(sut.status, .missing)
        XCTAssertTrue(sut.status.needsKeyring)
    }

    // MARK: - The right keyring

    func testStatusIsPresentWhenTheKeyringBelongsToTheSignedInAccount() async {
        KeyringTestSupport.installKeyring()
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))

        await sut.refresh()

        XCTAssertEqual(sut.status, .present)
        XCTAssertFalse(sut.status.needsKeyring)
    }

    func testARotatedKeyringStillReadsAsPresent() async {
        // Several versions, the last active. Rotation must not look like a foreign keyring.
        KeyringTestSupport.installRotatedKeyring(versions: 3)
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))

        await sut.refresh()

        XCTAssertEqual(sut.status, .present)
    }

    // MARK: - Somebody else's keyring

    func testStatusFlagsAKeyringLeftBehindByAnotherAccount() async {
        KeyringTestSupport.installKeyring()
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForOtherUser))

        await sut.refresh()

        // Signed out of one account and into another without forgetting the key. Separated from
        // `.missing` because the symptom differs: every note fails to decrypt rather than the app
        // reporting it has no key — but both need the same prompt, hence `needsKeyring`.
        XCTAssertEqual(sut.status, .belongsToAnotherAccount)
        XCTAssertTrue(sut.status.needsKeyring)
    }

    // MARK: - Unknown account

    func testAKeyringIsTrustedWhenTheAccountCannotBeDetermined() async {
        KeyringTestSupport.installKeyring()
        // No auth service at all — the same shape as a token this build cannot read.
        let sut = KeyringStatusService()

        await sut.refresh()

        // Deliberately `.present`: an unreadable session is a session problem, and sending the user
        // off to restore a key they are holding would be the wrong instruction.
        XCTAssertEqual(sut.status, .present)
    }

    // MARK: - Transitions

    func testRefreshGoesPresentOnceAKeyringArrives() async {
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))
        await sut.refresh()
        XCTAssertEqual(sut.status, .missing)

        // A recovery kit typed in, or a device paired.
        KeyringTestSupport.installKeyring()
        await sut.refresh()

        XCTAssertEqual(sut.status, .present)
    }

    func testRefreshGoesMissingAfterTheKeyringIsForgotten() async {
        KeyringTestSupport.installKeyring()
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))
        await sut.refresh()
        XCTAssertEqual(sut.status, .present)

        // Settings › Remove Keys.
        KeyringTestSupport.clear()
        await sut.refresh()

        XCTAssertEqual(sut.status, .missing)
    }

    // MARK: - Sign-out

    func testResetForgetsWhatItLearned() async {
        KeyringTestSupport.installKeyring()
        let sut = KeyringStatusService(authService: signedIn(as: Self.tokenForTestUser))
        await sut.refresh()
        XCTAssertEqual(sut.status, .present)

        sut.reset()

        // The next account to sign in on this device must be judged against its own keyring.
        XCTAssertEqual(sut.status, .unknown)
        XCTAssertFalse(sut.status.needsKeyring)
    }
}
