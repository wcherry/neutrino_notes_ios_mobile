import Foundation
import LocalAuthentication
import os.log

// MARK: - AppLockBiometry

/// Which biometric sensor this device offers, reduced to the cases the UI has words and icons for.
enum AppLockBiometry: Equatable {
    case none
    case touchID
    case faceID
    case opticID

    /// What to call it on screen. `.none` reads as "Passcode" because that is what the user will
    /// actually be asked for: the app evaluates `deviceOwnerAuthentication`, which falls back to
    /// the device passcode on hardware with no sensor.
    var label: String {
        switch self {
        case .none:    return "Passcode"
        case .touchID: return "Touch ID"
        case .faceID:  return "Face ID"
        case .opticID: return "Optic ID"
        }
    }

    var iconName: String {
        switch self {
        case .none:    return "lock.fill"
        case .touchID: return "touchid"
        case .faceID:  return "faceid"
        case .opticID: return "opticid"
        }
    }
}

// MARK: - AppLockAuthError

/// The outcome of a failed authentication, in the terms the lock screen cares about.
enum AppLockAuthError: Error, Equatable {
    /// The user dismissed the prompt or tapped Cancel. Not a failure worth showing a message for.
    case cancelled
    /// Too many failed biometric attempts; the sensor is disabled until a passcode is entered.
    case biometryLockout
    /// The device has no passcode, so there is no owner check to perform and no lock to offer.
    case passcodeNotSet
    /// Everything else, carrying the system's description.
    case failed(String)

    /// The line to put under the unlock button, or `nil` when the user already knows what happened.
    var message: String? {
        switch self {
        case .cancelled:      return nil
        case .biometryLockout: return "Biometrics are locked out. Enter your device passcode to unlock."
        case .passcodeNotSet:  return "Set a device passcode to use app lock."
        case .failed(let description): return description
        }
    }
}

// MARK: - BiometricAuthenticating

/// The owner check behind app lock, behind a protocol so tests can drive every branch without a
/// sensor, a passcode, or a human.
protocol BiometricAuthenticating: AnyObject {
    /// The sensor this device has, or `.none`.
    var biometry: AppLockBiometry { get }

    /// True when the device can check the owner's identity at all — a sensor, or failing that a
    /// passcode. False on a device with no passcode set, where app lock cannot be offered.
    func canEvaluate() -> Bool

    /// Prompts for biometrics, falling back to the device passcode. Throws `AppLockAuthError`.
    func evaluate(reason: String) async throws
}

// MARK: - SystemBiometricAuthenticator

/// `LocalAuthentication`-backed implementation.
///
/// Every call builds a **fresh** `LAContext`. A context caches its successful evaluation for
/// `touchIDAuthenticationAllowableReuseDuration` and, more importantly, is a one-shot object in
/// practice — reusing one across unlocks is the standard way to end up with a lock screen that
/// lets people in without asking.
final class SystemBiometricAuthenticator: BiometricAuthenticating {

    // MARK: - Private

    /// `deviceOwnerAuthentication`, not `deviceOwnerAuthenticationWithBiometrics`: the biometric-only
    /// policy has no passcode fallback, so a user whose face is not recognised — or whose sensor is
    /// locked out after five failures — would be shut out of their own notes with no way back in.
    private static let policy: LAPolicy = .deviceOwnerAuthentication

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "AppLock")

    // MARK: - BiometricAuthenticating

    var biometry: AppLockBiometry {
        let context = LAContext()
        // `biometryType` is only populated after a canEvaluatePolicy call.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return .touchID
        case .faceID:  return .faceID
        default:
            if #available(iOS 17.0, *), context.biometryType == .opticID { return .opticID }
            return .none
        }
    }

    func canEvaluate() -> Bool {
        LAContext().canEvaluatePolicy(Self.policy, error: nil)
    }

    func evaluate(reason: String) async throws {
        let context = LAContext()
        // The prompt's own cancel button is enough; a second "Enter Password" affordance would
        // suggest an app-level password that does not exist.
        context.localizedFallbackTitle = ""

        do {
            let success = try await context.evaluatePolicy(Self.policy, localizedReason: reason)
            guard success else { throw AppLockAuthError.failed("Authentication failed.") }
        } catch let error as LAError {
            logger.debug("evaluate failed: code=\(error.code.rawValue, privacy: .public)")
            throw Self.mapped(error)
        }
    }

    // MARK: - Error Mapping

    private static func mapped(_ error: LAError) -> AppLockAuthError {
        switch error.code {
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        case .biometryLockout:
            return .biometryLockout
        case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable:
            // All three land in the same place from the user's side: there is no owner check
            // available, and `deviceOwnerAuthentication` only reports them when no passcode
            // exists either.
            return .passcodeNotSet
        default:
            return .failed(error.localizedDescription)
        }
    }
}
