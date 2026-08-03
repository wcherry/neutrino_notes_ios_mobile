import XCTest
@testable import NeutrinoNotes

// MARK: - FakeBiometricAuthenticator

/// Stands in for `LocalAuthentication` so every branch of the lock can be driven without a sensor,
/// a passcode, or a human tapping a system prompt.
private final class FakeBiometricAuthenticator: BiometricAuthenticating {

    var biometry: AppLockBiometry = .faceID
    var available = true
    var result: Result<Void, AppLockAuthError> = .success(())

    private(set) var evaluateCount = 0
    private(set) var reasons: [String] = []

    func canEvaluate() -> Bool { available }

    func evaluate(reason: String) async throws {
        evaluateCount += 1
        reasons.append(reason)
        try result.get()
    }
}

// MARK: - AppLockServiceTests

/// Tests for `AppLockService`, the Phase 8 Face ID / Touch ID lock. Every test gets a throwaway
/// `UserDefaults` suite, a fake authenticator, and a hand-cranked clock, so nothing here touches
/// the real preferences and no test has to wait out a grace period.
@MainActor
final class AppLockServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var auth: FakeBiometricAuthenticator!
    private var clock: Date!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        suiteName = "AppLockServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        auth = FakeBiometricAuthenticator()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        super.tearDown()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        auth = nil
        clock = nil
    }

    // MARK: - Helpers

    private func makeService() -> AppLockService {
        AppLockService(defaults: defaults, authenticator: auth, now: { self.clock })
    }

    /// Builds a service that is already switched on, without spending a test on the enabling flow.
    private func makeEnabledService() -> AppLockService {
        defaults.set(true, forKey: AppLockService.enabledKey)
        return makeService()
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    // MARK: - Initial State

    func test_freshInstall_isOffAndUnlocked() {
        let sut = makeService()

        XCTAssertFalse(sut.isEnabled)
        XCTAssertFalse(sut.isLocked)
        XCTAssertEqual(sut.timeout, .immediately)
        XCTAssertNil(sut.lastError)
    }

    /// A launch is the strongest form of "the app was away", so an enabled lock starts locked
    /// no matter what grace period is configured.
    func test_launch_withLockEnabled_startsLocked() {
        defaults.set(true, forKey: AppLockService.enabledKey)
        defaults.set(AppLockTimeout.fifteenMinutes.rawValue, forKey: AppLockService.timeoutKey)

        let sut = makeService()

        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.timeout, .fifteenMinutes)
    }

    func test_biometryAndAvailability_comeFromTheAuthenticator() {
        auth.biometry = .touchID
        auth.available = false

        let sut = makeService()

        XCTAssertEqual(sut.biometry, .touchID)
        XCTAssertFalse(sut.isAvailable)
    }

    // MARK: - Enabling

    func test_setEnabled_true_authenticatesAndPersists() async {
        let sut = makeService()

        let changed = await sut.setEnabled(true)

        XCTAssertTrue(changed)
        XCTAssertTrue(sut.isEnabled)
        XCTAssertEqual(auth.evaluateCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AppLockService.enabledKey))
    }

    /// The user just proved who they are, so turning the lock on must not immediately drop them
    /// onto a lock screen.
    func test_setEnabled_true_doesNotLockImmediately() async {
        let sut = makeService()

        await sut.setEnabled(true)

        XCTAssertFalse(sut.isLocked)
    }

    func test_setEnabled_true_authenticationFailed_leavesLockOff() async {
        auth.result = .failure(.failed("No match"))
        let sut = makeService()

        let changed = await sut.setEnabled(true)

        XCTAssertFalse(changed)
        XCTAssertFalse(sut.isEnabled)
        XCTAssertEqual(sut.lastError, .failed("No match"))
        XCTAssertFalse(defaults.bool(forKey: AppLockService.enabledKey))
    }

    /// With no passcode there is no owner check to perform, so the prompt is never even shown.
    func test_setEnabled_true_whenUnavailable_reportsPasscodeNotSetWithoutPrompting() async {
        auth.available = false
        let sut = makeService()

        let changed = await sut.setEnabled(true)

        XCTAssertFalse(changed)
        XCTAssertFalse(sut.isEnabled)
        XCTAssertEqual(sut.lastError, .passcodeNotSet)
        XCTAssertEqual(auth.evaluateCount, 0)
    }

    func test_setEnabled_toCurrentValue_isANoOp() async {
        let sut = makeService()

        let changed = await sut.setEnabled(false)

        XCTAssertFalse(changed)
        XCTAssertEqual(auth.evaluateCount, 0)
    }

    // MARK: - Disabling

    /// Turning the lock *off* is gated too, so a bystander holding an unlocked phone cannot
    /// quietly remove the protection.
    func test_setEnabled_false_requiresAuthentication() async {
        let sut = makeEnabledService()
        await sut.unlock()
        auth.result = .failure(.cancelled)

        let changed = await sut.setEnabled(false)

        XCTAssertFalse(changed)
        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AppLockService.enabledKey))
    }

    func test_setEnabled_false_authenticated_persistsAndClearsLock() async {
        let sut = makeEnabledService()

        let changed = await sut.setEnabled(false)

        XCTAssertTrue(changed)
        XCTAssertFalse(sut.isEnabled)
        XCTAssertFalse(sut.isLocked)
        XCTAssertFalse(defaults.bool(forKey: AppLockService.enabledKey))
    }

    // MARK: - Unlocking

    func test_unlock_succeeds() async {
        let sut = makeEnabledService()

        await sut.unlock()

        XCTAssertFalse(sut.isLocked)
        XCTAssertNil(sut.lastError)
        XCTAssertEqual(auth.reasons, ["Unlock Neutrino Notes"])
    }

    /// A cancel is not a failure worth shouting about: the lock screen and its button are still
    /// there, and `.cancelled` deliberately carries no message.
    func test_unlock_cancelled_staysLockedWithNoMessage() async {
        auth.result = .failure(.cancelled)
        let sut = makeEnabledService()

        await sut.unlock()

        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .cancelled)
        XCTAssertNil(sut.lastError?.message)
    }

    func test_unlock_biometryLockout_staysLockedAndExplains() async {
        auth.result = .failure(.biometryLockout)
        let sut = makeEnabledService()

        await sut.unlock()

        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .biometryLockout)
        XCTAssertNotNil(sut.lastError?.message)
    }

    func test_unlock_afterFailure_clearsThePreviousError() async {
        auth.result = .failure(.failed("No match"))
        let sut = makeEnabledService()
        await sut.unlock()

        auth.result = .success(())
        await sut.unlock()

        XCTAssertFalse(sut.isLocked)
        XCTAssertNil(sut.lastError)
    }

    /// An already-unlocked app must never prompt — `LockScreenView.task` fires on every appearance.
    func test_unlock_whenNotLocked_doesNotPrompt() async {
        let sut = makeService()

        await sut.unlock()

        XCTAssertEqual(auth.evaluateCount, 0)
    }

    // MARK: - Lock Now

    func test_lockNow_locks() async {
        let sut = makeEnabledService()
        await sut.unlock()

        sut.lockNow()

        XCTAssertTrue(sut.isLocked)
        // Locking is the safe direction; it never asks for proof of identity.
        XCTAssertEqual(auth.evaluateCount, 1)
    }

    func test_lockNow_whenDisabled_doesNothing() {
        let sut = makeService()

        sut.lockNow()

        XCTAssertFalse(sut.isLocked)
    }

    // MARK: - Auto-Lock

    func test_background_thenActive_withImmediateTimeout_locks() async {
        let sut = makeEnabledService()
        await sut.unlock()

        sut.didEnterBackground()
        sut.didBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    func test_returnInsideGracePeriod_staysUnlocked() async {
        let sut = makeEnabledService()
        await sut.unlock()
        sut.setTimeout(.fiveMinutes)

        sut.didEnterBackground()
        advance(60)
        sut.didBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    func test_returnAfterGracePeriod_locks() async {
        let sut = makeEnabledService()
        await sut.unlock()
        sut.setTimeout(.fiveMinutes)

        sut.didEnterBackground()
        advance(301)
        sut.didBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    /// The grace period is measured per trip. A return inside it consumes the timestamp, so time
    /// spent using the app afterwards is not counted against the next backgrounding.
    func test_gracePeriodIsMeasuredPerTrip() async {
        let sut = makeEnabledService()
        await sut.unlock()
        sut.setTimeout(.fiveMinutes)

        sut.didEnterBackground()
        advance(60)
        sut.didBecomeActive()

        advance(3600)   // a long session in the foreground
        sut.didEnterBackground()
        advance(10)
        sut.didBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    /// Becoming active without a preceding `background` is what a dismissed biometric prompt looks
    /// like — the scene only ever went `.inactive`. It must not lock.
    func test_becomingActiveWithoutBackgrounding_doesNotLock() async {
        let sut = makeEnabledService()
        await sut.unlock()

        sut.didBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    func test_sceneChanges_whenLockIsOff_doNothing() {
        let sut = makeService()

        sut.didEnterBackground()
        advance(3600)
        sut.didBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    func test_backgroundingWhileLocked_leavesItLocked() {
        let sut = makeEnabledService()

        sut.didEnterBackground()
        sut.didBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    // MARK: - Timeout Preference

    func test_setTimeout_persists() {
        let sut = makeService()

        sut.setTimeout(.fifteenMinutes)

        XCTAssertEqual(sut.timeout, .fifteenMinutes)
        XCTAssertEqual(defaults.integer(forKey: AppLockService.timeoutKey),
                       AppLockTimeout.fifteenMinutes.rawValue)
        XCTAssertEqual(makeService().timeout, .fifteenMinutes)
    }

    // MARK: - Presentation

    func test_shouldPresentLockScreen_onlyWhenEnabledAndLocked() async {
        let off = makeService()
        XCTAssertFalse(off.shouldPresentLockScreen)
        XCTAssertFalse(off.shouldShieldContent)

        let on = makeEnabledService()
        XCTAssertEqual(on.shouldPresentLockScreen, FeatureFlags.appLock)
        XCTAssertEqual(on.shouldShieldContent, FeatureFlags.appLock)

        await on.unlock()
        XCTAssertFalse(on.shouldPresentLockScreen)
        // The app switcher snapshot is still hidden while the lock is switched on, even unlocked.
        XCTAssertEqual(on.shouldShieldContent, FeatureFlags.appLock)
    }

    // MARK: - Errors

    func test_clearError_removesTheMessage() async {
        auth.result = .failure(.failed("No match"))
        let sut = makeEnabledService()
        await sut.unlock()

        sut.clearError()

        XCTAssertNil(sut.lastError)
    }
}
