import XCTest
@testable import NeutrinoNotes

/// Tests for `NetworkMonitor`. Every test uses `autoStart: false` so the process never starts a
/// real `NWPathMonitor`; `setOnlineForTesting(_:)` drives the published state instead.
@MainActor
final class NetworkMonitorTests: XCTestCase {

    func test_init_withAutoStartFalse_isInertAndDefaultsOnline() {
        let monitor = NetworkMonitor(autoStart: false)

        // Optimistic default documented on the property itself: assume connectivity until told
        // otherwise, so the first sync attempt after launch isn't needlessly suppressed.
        XCTAssertTrue(monitor.isOnline)
    }

    func test_setOnlineForTesting_false_drivesIsOnlineFalse() {
        let monitor = NetworkMonitor(autoStart: false)

        monitor.setOnlineForTesting(false)

        XCTAssertFalse(monitor.isOnline)
    }

    func test_setOnlineForTesting_trueAfterFalse_drivesIsOnlineTrue() {
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)

        monitor.setOnlineForTesting(true)

        XCTAssertTrue(monitor.isOnline)
    }

    func test_setOnlineForTesting_sameValueRepeated_staysStable() {
        let monitor = NetworkMonitor(autoStart: false)

        monitor.setOnlineForTesting(false)
        monitor.setOnlineForTesting(false)
        XCTAssertFalse(monitor.isOnline)

        monitor.setOnlineForTesting(true)
        monitor.setOnlineForTesting(true)
        XCTAssertTrue(monitor.isOnline)
    }

    func test_stop_withoutStart_isSafeNoOp() {
        let monitor = NetworkMonitor(autoStart: false)

        monitor.stop()

        XCTAssertTrue(monitor.isOnline)
    }
}
