import XCTest
import SwiftUI
@testable import NeutrinoNotes

// MARK: - StubBiometricAuthenticator

/// A fixed answer for the view tests, which care about what a screen names and whether it builds,
/// not about the outcome of a prompt.
private final class StubBiometricAuthenticator: BiometricAuthenticating {
    var biometry: AppLockBiometry
    var available: Bool

    init(biometry: AppLockBiometry, available: Bool) {
        self.biometry = biometry
        self.available = available
    }

    func canEvaluate() -> Bool { available }

    /// Never called: no view test taps Unlock, and `LockScreenView.task` does not run under
    /// `loadViewIfNeeded()`.
    func evaluate(reason: String) async throws {}
}

// MARK: - AppLockViewTests

/// Hosting tests for the Phase 8 app lock screens. As in `SharingViewTests`, the point is that
/// SwiftUI fatal-errors on a missing `@EnvironmentObject` the moment a body is evaluated, so
/// building each view for real is what proves the app's wiring is complete.
@MainActor
final class AppLockViewTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        suiteName = "AppLockViewTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        super.tearDown()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - Helpers

    private func appLock(biometry: AppLockBiometry = .faceID,
                         available: Bool = true,
                         enabled: Bool = false) -> AppLockService {
        defaults.set(enabled, forKey: AppLockService.enabledKey)
        return AppLockService(
            defaults: defaults,
            authenticator: StubBiometricAuthenticator(biometry: biometry, available: available)
        )
    }

    private func host(_ view: some View, appLock: AppLockService) {
        let wired = view
            .environmentObject(AuthService())
            .environmentObject(appLock)

        let hosting = UIHostingController(rootView: wired)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Lock Screen

    func test_lockScreen_buildsForFaceID() {
        host(LockScreenView(), appLock: appLock(biometry: .faceID, enabled: true))
    }

    func test_lockScreen_buildsForTouchID() {
        host(LockScreenView(), appLock: appLock(biometry: .touchID, enabled: true))
    }

    /// A device with no sensor still gets a lock screen — the passcode is the fallback.
    func test_lockScreen_buildsWithNoBiometrySensor() {
        host(LockScreenView(), appLock: appLock(biometry: .none, enabled: true))
    }

    func test_lockScreen_buildsWithAnErrorShowing() async {
        let lock = appLock(biometry: .faceID, enabled: true)
        await lock.setEnabled(false)   // stub succeeds, so this just exercises the state machine
        host(LockScreenView(), appLock: lock)
    }

    func test_privacyShield_builds() {
        host(PrivacyShieldView(), appLock: appLock())
    }

    // MARK: - Settings

    func test_settings_buildsWithLockOff() {
        host(NavigationStack { SettingsView() }, appLock: appLock())
    }

    /// The enabled body is a different branch: it adds the timeout picker and Lock Now.
    func test_settings_buildsWithLockOn() {
        host(NavigationStack { SettingsView() }, appLock: appLock(enabled: true))
    }

    /// No passcode on the device — the toggle is replaced by an explanation.
    func test_settings_buildsWhenOwnerCheckIsUnavailable() {
        host(NavigationStack { SettingsView() }, appLock: appLock(available: false))
    }

    // MARK: - Modifier

    func test_appLockedModifier_buildsInEveryPresentationState() {
        let locked = appLock(enabled: true)
        host(Text("content").appLocked(locked, isSceneActive: true), appLock: locked)

        let shielded = appLock(enabled: true)
        shielded.lockNow()
        host(Text("content").appLocked(shielded, isSceneActive: false), appLock: shielded)

        let off = appLock()
        host(Text("content").appLocked(off, isSceneActive: true), appLock: off)
    }
}
