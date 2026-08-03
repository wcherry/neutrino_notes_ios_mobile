import XCTest
import LocalAuthentication
@testable import NeutrinoNotes

/// Tests for the vocabulary around the owner check: what each sensor is called, and what a failed
/// attempt tells the user. The `LAContext` evaluation itself is not testable in a unit test — it
/// needs real hardware and a real human — which is exactly why `BiometricAuthenticating` exists.
final class BiometricAuthenticatorTests: XCTestCase {

    // MARK: - Biometry

    func test_biometryLabels_matchApplesNames() {
        XCTAssertEqual(AppLockBiometry.faceID.label, "Face ID")
        XCTAssertEqual(AppLockBiometry.touchID.label, "Touch ID")
        XCTAssertEqual(AppLockBiometry.opticID.label, "Optic ID")
    }

    /// A device with no sensor is still lockable — `deviceOwnerAuthentication` falls back to the
    /// passcode — so `.none` has to read as something the user can act on, not as "unavailable".
    func test_noBiometry_isNamedForThePasscodeFallback() {
        XCTAssertEqual(AppLockBiometry.none.label, "Passcode")
    }

    func test_biometryIcons_areDistinct() {
        let icons: [AppLockBiometry] = [.none, .touchID, .faceID, .opticID]
        let names = icons.map(\.iconName)

        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }

    // MARK: - Errors

    /// A cancel is the user closing a prompt they opened. The lock screen already says what to do,
    /// so an error line under the button would just be noise.
    func test_cancelled_hasNoMessage() {
        XCTAssertNil(AppLockAuthError.cancelled.message)
    }

    func test_recoverableFailures_explainTheWayOut() {
        XCTAssertNotNil(AppLockAuthError.biometryLockout.message)
        XCTAssertNotNil(AppLockAuthError.passcodeNotSet.message)
        // A lockout is only escapable via the passcode, so the message has to say so.
        XCTAssertTrue(AppLockAuthError.biometryLockout.message?.contains("passcode") ?? false)
    }

    func test_failed_surfacesTheSystemDescription() {
        XCTAssertEqual(AppLockAuthError.failed("Face ID does not recognize you.").message,
                       "Face ID does not recognize you.")
    }

    // MARK: - System Authenticator

    /// The simulator has no passcode and no enrolled biometrics, so this asserts only that the
    /// real authenticator answers both availability questions without throwing or hanging.
    func test_systemAuthenticator_reportsAvailabilityWithoutPrompting() {
        let sut = SystemBiometricAuthenticator()

        _ = sut.canEvaluate()
        _ = sut.biometry
    }

    /// `biometry` has to build its own `LAContext` and prime it with a `canEvaluatePolicy` call —
    /// `biometryType` is `.none` on an untouched context — so reading it twice must give the same
    /// answer rather than depending on what was asked first.
    func test_systemAuthenticator_biometryIsStableAcrossReads() {
        let sut = SystemBiometricAuthenticator()

        XCTAssertEqual(sut.biometry, sut.biometry)
    }
}
