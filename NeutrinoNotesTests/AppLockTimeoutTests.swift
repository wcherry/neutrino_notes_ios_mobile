import XCTest
@testable import NeutrinoNotes

/// Tests for `AppLockTimeout`, the auto-lock grace period behind Phase 8's app lock.
final class AppLockTimeoutTests: XCTestCase {

    // MARK: - Raw Values

    func test_rawValues_areDurationsInSeconds() {
        XCTAssertEqual(AppLockTimeout.immediately.rawValue, 0)
        XCTAssertEqual(AppLockTimeout.oneMinute.rawValue, 60)
        XCTAssertEqual(AppLockTimeout.fiveMinutes.rawValue, 300)
        XCTAssertEqual(AppLockTimeout.fifteenMinutes.rawValue, 900)
    }

    func test_interval_matchesRawValue() {
        for option in AppLockTimeout.allCases {
            XCTAssertEqual(option.interval, TimeInterval(option.rawValue), "\(option)")
        }
    }

    func test_allCases_areOrderedShortestFirst() {
        XCTAssertEqual(AppLockTimeout.allCases.map(\.rawValue), [0, 60, 300, 900])
    }

    // MARK: - Elapsing

    func test_immediately_elapsesWithNoTimeAtAll() {
        let instant = Date()

        XCTAssertTrue(AppLockTimeout.immediately.hasElapsed(since: instant, now: instant))
    }

    func test_timeout_hasNotElapsed_beforeTheGracePeriodIsUp() {
        let left = Date()
        let back = left.addingTimeInterval(59)

        XCTAssertFalse(AppLockTimeout.oneMinute.hasElapsed(since: left, now: back))
    }

    func test_timeout_elapses_exactlyOnTheBoundary() {
        let left = Date()
        let back = left.addingTimeInterval(60)

        XCTAssertTrue(AppLockTimeout.oneMinute.hasElapsed(since: left, now: back))
    }

    func test_timeout_elapses_wellPastTheGracePeriod() {
        let left = Date()
        let back = left.addingTimeInterval(3600)

        XCTAssertTrue(AppLockTimeout.fifteenMinutes.hasElapsed(since: left, now: back))
    }

    /// A device clock that moved backwards while the app was away must not hand out a longer grace
    /// period than the user asked for.
    func test_clockMovedBackwards_doesNotExtendTheGracePeriod() {
        let left = Date()
        let back = left.addingTimeInterval(-3600)

        XCTAssertFalse(AppLockTimeout.oneMinute.hasElapsed(since: left, now: back))
        XCTAssertFalse(AppLockTimeout.immediately.hasElapsed(since: left, now: back))
    }

    // MARK: - Persistence

    func test_default_isImmediately() {
        XCTAssertEqual(AppLockTimeout.default, .immediately)
    }

    func test_storedValue_roundTripsEveryCase() {
        for option in AppLockTimeout.allCases {
            XCTAssertEqual(AppLockTimeout(storedValue: option.rawValue), option)
        }
    }

    /// `UserDefaults.integer(forKey:)` returns 0 for a key that was never written, which has to
    /// mean "immediately" rather than crashing or meaning "never".
    func test_storedValue_unknownFallsBackToDefault() {
        XCTAssertEqual(AppLockTimeout(storedValue: 42), .default)
        XCTAssertEqual(AppLockTimeout(storedValue: -1), .default)
        XCTAssertEqual(AppLockTimeout(storedValue: 0), .immediately)
    }

    // MARK: - Display

    func test_labels_areDistinctAndNonEmpty() {
        let labels = AppLockTimeout.allCases.map(\.label)

        XCTAssertEqual(Set(labels).count, AppLockTimeout.allCases.count)
        XCTAssertFalse(labels.contains(where: \.isEmpty))
    }
}
