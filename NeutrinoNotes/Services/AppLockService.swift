import Foundation
import os.log

// MARK: - AppLockService

/// Face ID / Touch ID lock for the app itself (roadmap Phase 8).
///
/// What this protects, precisely: **the screen**. Notes are end-to-end encrypted and the keys live
/// in the Keychain, so a stolen device already denies an attacker the *files*. What it does not
/// deny them is a running, signed-in app handed over unlocked — the "let me show you something on
/// my phone" case. App lock closes that gap and nothing more; it is not a second encryption layer
/// and does not re-wrap anything.
///
/// Three deliberate choices:
///
/// * **The passcode is always a fallback.** `SystemBiometricAuthenticator` evaluates
///   `deviceOwnerAuthentication`, so a face the sensor will not recognise, a lockout after five
///   failures, or a cracked front camera all still leave a way in. A biometrics-only policy would
///   turn a hardware fault into permanent loss of access to notes that sync fine everywhere else.
/// * **The setting itself is guarded.** Turning lock on *or off* requires passing the same check,
///   so someone holding an unlocked phone cannot quietly remove the protection.
/// * **The grace period is measured from backgrounding.** The biometric prompt drops the scene to
///   `.inactive`, so `didEnterBackground()`/`didBecomeActive()` are wired only to `.background`
///   and `.active`; otherwise every unlock attempt would restart the timer it is racing.
///
/// The enabled flag and timeout live in `UserDefaults`, not the Keychain. They are a UI preference,
/// not a secret, and the thing being protected is the foreground app rather than data at rest —
/// an attacker who can rewrite this app's defaults has already lost the user the device.
@MainActor
final class AppLockService: ObservableObject {

    // MARK: - Published State

    /// True when the lock screen should be covering the app's content.
    @Published private(set) var isLocked: Bool = false

    /// True when the user has turned app lock on.
    @Published private(set) var isEnabled: Bool = false

    /// How long the app may stay backgrounded before re-locking.
    @Published private(set) var timeout: AppLockTimeout = .default

    /// True while a system prompt is on screen. The UI uses it to avoid stacking prompts; the
    /// service uses it to make a second concurrent `unlock()` a no-op.
    @Published private(set) var isAuthenticating: Bool = false

    /// The last failure worth telling the user about, or `nil`. Cleared on every new attempt and
    /// on success. A plain cancel leaves this `nil`.
    @Published private(set) var lastError: AppLockAuthError?

    // MARK: - Configuration

    static let enabledKey = "nn.appLock.enabled"
    static let timeoutKey = "nn.appLock.timeoutSeconds"

    // MARK: - Private

    private let defaults: UserDefaults
    private let authenticator: any BiometricAuthenticating
    private let now: () -> Date

    /// When the app was last backgrounded, or `nil` if it has not been since the last unlock.
    private var backgroundedAt: Date?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "AppLock")

    // MARK: - Init

    /// - Parameters:
    ///   - defaults: `nil` uses `.standard`. Tests pass a throwaway suite.
    ///   - authenticator: the owner check. Tests pass a fake.
    ///   - now: the clock, injectable so timeout tests do not have to wait.
    init(defaults: UserDefaults = .standard,
         authenticator: any BiometricAuthenticating = SystemBiometricAuthenticator(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.timeout = AppLockTimeout(storedValue: defaults.integer(forKey: Self.timeoutKey))
        // A launch is the strongest form of "the app was away": if lock is on, it starts locked
        // regardless of timeout. There is no backgrounding timestamp to compare against, and a
        // grace period that survived a process death would be a grace period across a reboot.
        self.isLocked = isEnabled
    }

    // MARK: - Availability

    /// Which sensor to name on the lock screen and in Settings.
    var biometry: AppLockBiometry { authenticator.biometry }

    /// True when this device can check the owner's identity at all. False means no passcode is set,
    /// and Settings says so instead of offering a toggle that would fail on the first tap.
    var isAvailable: Bool { authenticator.canEvaluate() }

    /// The lock screen only belongs in front of content when the feature is on *and* the user
    /// enabled it. Reading the flag here keeps the check in one place.
    var shouldPresentLockScreen: Bool { FeatureFlags.appLock && isEnabled && isLocked }

    /// Whether to hide content behind the privacy shield while the app is off screen. Tied to the
    /// same setting: a user who has not asked for a lock has not asked for an obscured app switcher
    /// card either.
    var shouldShieldContent: Bool { FeatureFlags.appLock && isEnabled }

    // MARK: - Unlocking

    /// Runs the owner check and, on success, unlocks.
    ///
    /// A cancel leaves the app locked with no error message — the user closed the prompt on
    /// purpose and the lock screen's button is still there.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        lastError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await authenticator.evaluate(reason: "Unlock Neutrino Notes")
            isLocked = false
            backgroundedAt = nil
            logger.debug("unlock: succeeded")
        } catch {
            lastError = error as? AppLockAuthError ?? .failed("Authentication failed.")
            logger.debug("unlock: failed")
        }
    }

    /// Locks immediately, for the "Lock Now" action in Settings. No authentication required —
    /// making something *more* protected never needs proof of identity.
    func lockNow() {
        guard isEnabled else { return }
        lastError = nil
        isLocked = true
        backgroundedAt = nil
        logger.debug("lockNow")
    }

    // MARK: - Settings

    /// Turns app lock on or off, gated on the same owner check either way.
    ///
    /// Enabling proves the check works before the user is ever locked behind it; disabling stops a
    /// bystander with an unlocked phone from removing the lock. Returns `true` when the setting
    /// changed, so the caller can revert a toggle whose animation already fired.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != isEnabled, !isAuthenticating else { return false }

        guard !enabled || isAvailable else {
            lastError = .passcodeNotSet
            return false
        }

        lastError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        let reason = enabled ? "Turn on app lock for Neutrino Notes"
                             : "Turn off app lock for Neutrino Notes"
        do {
            try await authenticator.evaluate(reason: reason)
        } catch {
            lastError = error as? AppLockAuthError ?? .failed("Authentication failed.")
            logger.debug("setEnabled(\(enabled, privacy: .public)): authentication failed")
            return false
        }

        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        // The user just proved who they are, so enabling does not drop them onto a lock screen.
        // Disabling has to clear `isLocked` as well, or the flag would leave a stale lock behind
        // if it were ever turned back on without a relaunch.
        isLocked = false
        backgroundedAt = nil
        logger.debug("setEnabled: enabled=\(enabled, privacy: .public)")
        return true
    }

    /// Changes the grace period. Not gated: the toggle is what protects the feature, and this is
    /// only reachable from Settings inside an already-unlocked app.
    func setTimeout(_ newValue: AppLockTimeout) {
        guard newValue != timeout else { return }
        timeout = newValue
        defaults.set(newValue.rawValue, forKey: Self.timeoutKey)
        logger.debug("setTimeout: \(newValue.rawValue, privacy: .public)s")
    }

    /// Clears the error banner, e.g. when the lock screen is dismissed or a sheet closes.
    func clearError() {
        lastError = nil
    }

    // MARK: - Scene Lifecycle

    /// Call on `ScenePhase.background` only — see the type comment.
    func didEnterBackground() {
        guard isEnabled, !isLocked else { return }
        backgroundedAt = now()
    }

    /// Call on `ScenePhase.active`. Re-locks when the grace period has run out.
    ///
    /// The timestamp is consumed either way: a return inside the grace period ends that trip, and
    /// the next backgrounding starts a fresh one.
    func didBecomeActive() {
        guard isEnabled, !isLocked, let leftAt = backgroundedAt else { return }
        backgroundedAt = nil
        guard timeout.hasElapsed(since: leftAt, now: now()) else { return }
        isLocked = true
        lastError = nil
        logger.debug("didBecomeActive: re-locked after \(self.timeout.rawValue, privacy: .public)s timeout")
    }
}
