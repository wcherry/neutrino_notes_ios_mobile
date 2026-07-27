import XCTest
@testable import NeutrinoNotes

/// Tests for AuthService.
///
/// AuthService reads from and writes to the real simulator Keychain, which is
/// perfectly acceptable for unit tests running in the simulator sandbox.
/// Each test method seeds the Keychain state it needs in setUp/the test body
/// and cleans up in tearDown so tests are fully independent of one another.
///
/// Network-dependent tests (login success, refresh) require a running server at
/// localhost:8080.  They are skipped here and covered by integration tests.
/// What IS tested without a server:
///   - init restores state from Keychain
///   - logout() clears all three Keychain keys (access, refresh, expiry)
///   - refreshTokenIfNeeded() is a no-op when the token is fresh
///   - refreshTokenIfNeeded() calls logout() when no refresh token is stored
///   - login() with unreachable server sets loginError rather than crashing
@MainActor
final class AuthServiceTests: XCTestCase {

    // Keychain keys — duplicated here to avoid coupling the tests to the
    // production constants before they are public.
    private let accessTokenKey  = "nn.access_token"
    private let refreshTokenKey = "nn.refresh_token"
    private let expiryKey       = "nn.token_expiry"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        KeychainService.delete(forKey: accessTokenKey)
        KeychainService.delete(forKey: refreshTokenKey)
        KeychainService.delete(forKey: expiryKey)
    }

    override func tearDown() {
        super.tearDown()
        KeychainService.delete(forKey: accessTokenKey)
        KeychainService.delete(forKey: refreshTokenKey)
        KeychainService.delete(forKey: expiryKey)
    }

    // MARK: - init

    /// When no access token exists in the Keychain, a freshly created
    /// AuthService must start in the unauthenticated state.
    func test_init_withNoTokenInKeychain_isAuthenticatedIsFalse() {
        let sut = AuthService()
        XCTAssertFalse(sut.isAuthenticated,
                       "AuthService should not be authenticated when no access token is stored")
    }

    /// When a valid access token is already present in the Keychain, a freshly
    /// created AuthService must restore the authenticated state without
    /// requiring a new login.
    func test_init_withAccessTokenInKeychain_isAuthenticatedIsTrue() {
        KeychainService.save("existing-access-token", forKey: accessTokenKey)

        let sut = AuthService()

        XCTAssertTrue(sut.isAuthenticated,
                      "AuthService should be authenticated when an access token is found in Keychain on init")
    }

    // MARK: - logout

    /// Calling logout() must flip isAuthenticated to false.
    func test_logout_setsIsAuthenticatedToFalse() {
        KeychainService.save("some-access-token",   forKey: accessTokenKey)
        KeychainService.save("some-refresh-token",  forKey: refreshTokenKey)
        let sut = AuthService()
        XCTAssertTrue(sut.isAuthenticated, "Precondition: should be authenticated before logout")

        sut.logout()

        XCTAssertFalse(sut.isAuthenticated,
                       "isAuthenticated should be false immediately after logout()")
    }

    /// After logout() the access token Keychain entry must be absent.
    func test_logout_deletesAccessTokenFromKeychain() {
        KeychainService.save("access-token-to-remove", forKey: accessTokenKey)
        let sut = AuthService()

        sut.logout()

        XCTAssertNil(KeychainService.load(forKey: accessTokenKey),
                     "Access token must be removed from Keychain after logout()")
    }

    /// After logout() the refresh token Keychain entry must be absent.
    func test_logout_deletesRefreshTokenFromKeychain() {
        KeychainService.save("access-token",          forKey: accessTokenKey)
        KeychainService.save("refresh-token-to-remove", forKey: refreshTokenKey)
        let sut = AuthService()

        sut.logout()

        XCTAssertNil(KeychainService.load(forKey: refreshTokenKey),
                     "Refresh token must be removed from Keychain after logout()")
    }

    /// After logout() the token expiry Keychain entry must also be absent.
    func test_logout_deletesTokenExpiryFromKeychain() {
        KeychainService.save("access-token",  forKey: accessTokenKey)
        KeychainService.save("refresh-token", forKey: refreshTokenKey)
        // Write a fake expiry to verify it is cleared.
        let futureExpiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        KeychainService.save(futureExpiry, forKey: expiryKey)

        let sut = AuthService()
        sut.logout()

        XCTAssertNil(KeychainService.load(forKey: expiryKey),
                     "Token expiry must be removed from Keychain after logout()")
    }

    /// Calling logout() when there are no tokens in the Keychain must not crash.
    func test_logout_whenAlreadyLoggedOut_doesNotCrash() {
        let sut = AuthService()
        XCTAssertFalse(sut.isAuthenticated, "Precondition: should start unauthenticated")

        sut.logout() // Must not throw, trap, or hang.

        XCTAssertFalse(sut.isAuthenticated)
    }

    /// A second call to logout() after the first succeeds must also be safe.
    func test_logout_calledTwiceConsecutively_doesNotCrash() {
        KeychainService.save("access-token", forKey: accessTokenKey)
        let sut = AuthService()

        sut.logout()
        sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - @Published propagation

    /// isAuthenticated changes must propagate to Combine subscribers on the main actor.
    func test_logout_publishesIsAuthenticatedChange() {
        KeychainService.save("access-token", forKey: accessTokenKey)
        let sut = AuthService()

        var receivedValues: [Bool] = []
        let cancellable = sut.$isAuthenticated.sink { receivedValues.append($0) }

        sut.logout()

        XCTAssertEqual(receivedValues, [true, false],
                       "Publisher should emit true (initial) then false (after logout)")
        cancellable.cancel()
    }

    // MARK: - refreshTokenIfNeeded — no-op when token is fresh

    /// When a future expiry is stored, refreshTokenIfNeeded() must complete
    /// without altering isAuthenticated or clearing the Keychain.
    func test_refreshTokenIfNeeded_withFreshToken_isNoOp() async throws {
        // Store a token that expires one hour from now — well beyond the 60-second buffer.
        // Must match the plain ISO8601DateFormatter() (no fractional seconds) that
        // AuthService itself uses to write and read this value.
        let futureExpiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))

        KeychainService.save("access-token",  forKey: accessTokenKey)
        KeychainService.save("refresh-token", forKey: refreshTokenKey)
        KeychainService.save(futureExpiry,    forKey: expiryKey)

        let sut = AuthService()
        XCTAssertTrue(sut.isAuthenticated, "Precondition: should start authenticated")

        await sut.refreshTokenIfNeeded()

        // State is unchanged — no network call was attempted.
        XCTAssertTrue(sut.isAuthenticated,
                      "refreshTokenIfNeeded() must not alter isAuthenticated when token is fresh")
        XCTAssertNotNil(KeychainService.load(forKey: accessTokenKey),
                        "Access token must still be in Keychain after a no-op refresh")
    }

    // MARK: - refreshTokenIfNeeded — logs out when no refresh token is stored

    /// When there is no refresh token in the Keychain, refreshTokenIfNeeded()
    /// must call logout() rather than attempting a network request.
    func test_refreshTokenIfNeeded_withNoRefreshToken_callsLogout() async throws {
        // Store only an access token with an expired expiry (forces refresh path).
        let pastExpiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10))

        KeychainService.save("access-token", forKey: accessTokenKey)
        KeychainService.save(pastExpiry,     forKey: expiryKey)
        // Deliberately no refresh token.

        let sut = AuthService()
        XCTAssertTrue(sut.isAuthenticated, "Precondition: access token present → authenticated")

        await sut.refreshTokenIfNeeded()

        XCTAssertFalse(sut.isAuthenticated,
                       "When no refresh token exists, refreshTokenIfNeeded() must log out the user")
        XCTAssertNil(KeychainService.load(forKey: accessTokenKey),
                     "Access token must be cleared after logout triggered by missing refresh token")
    }

    // MARK: - login() — network error when server is unreachable

    /// Attempting login() against a server that is not running must not crash
    /// or hang, and must leave isAuthenticated false while surfacing an error.
    func test_login_withUnreachableServer_setsLoginErrorAndStaysUnauthenticated() async {
        let sut = AuthService()

        await sut.login(email: "test@example.com", password: "password")

        // Regardless of which auth error occurred (unreachable server, or a
        // running server rejecting stub credentials), isAuthenticated stays false
        // and a human-readable error is surfaced.
        XCTAssertFalse(sut.isAuthenticated,
                       "isAuthenticated must remain false when login fails")
        XCTAssertNotNil(sut.loginError,
                        "loginError must be set when login fails")
    }
}
