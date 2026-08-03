import Foundation

// MARK: - AppLockTimeout

/// How long the app may sit in the background before it re-locks.
///
/// The raw value is the grace period in seconds, which is also the stable value written to
/// `UserDefaults` — the cases are deliberately spelled as durations rather than an ordinal so a
/// future case can be inserted anywhere without rewriting anyone's stored preference.
///
/// The clock starts when the app is *backgrounded*, not when it goes inactive. Presenting the
/// system biometric prompt drops the scene to `.inactive`, so timing off inactivity would restart
/// the grace period every time the user was asked to unlock — see `AppLockService`.
enum AppLockTimeout: Int, CaseIterable, Identifiable, Codable, Hashable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    // MARK: - Identifiable

    var id: Int { rawValue }

    // MARK: - Timing

    var interval: TimeInterval { TimeInterval(rawValue) }

    /// True when this timeout has elapsed between `backgroundedAt` and `now`.
    ///
    /// `.immediately` has a zero interval, so any elapsed time — including none at all — is enough.
    /// A backgrounding timestamp in the future (the device clock moved backwards while the app was
    /// away) yields a negative elapsed time and only locks under `.immediately`, which is the safe
    /// reading: a moved clock must never *extend* someone's grace period.
    func hasElapsed(since backgroundedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(backgroundedAt) >= interval
    }

    // MARK: - Display

    var label: String {
        switch self {
        case .immediately:    return "Immediately"
        case .oneMinute:      return "After 1 minute"
        case .fiveMinutes:    return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        }
    }

    // MARK: - Persistence

    /// The safest default: a note is protected the moment the app leaves the screen. Someone who
    /// wants a grace period has to ask for one.
    static let `default` = AppLockTimeout.immediately

    /// Reads a stored preference, falling back to `.default` for anything unrecognised so a value
    /// written by a newer build (or a corrupted one) fails closed rather than crashing.
    init(storedValue: Int) {
        self = AppLockTimeout(rawValue: storedValue) ?? .default
    }
}
