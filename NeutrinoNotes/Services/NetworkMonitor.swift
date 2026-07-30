import Foundation
import Network
import os.log

// MARK: - NetworkMonitor

// Publishes whether the device currently has a usable network path, so the offline UI can
// switch modes and SyncEngine knows when to drain its queue. Backed by NWPathMonitor, which
// reports on a background queue — every update is hopped back onto the main actor before it
// touches published state.
@MainActor
final class NetworkMonitor: ObservableObject {

    // MARK: - Published State

    /// Optimistic default: assume connectivity until NWPathMonitor says otherwise, so the first
    /// sync attempt after launch is not needlessly suppressed.
    @Published private(set) var isOnline: Bool = true

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "NetworkMonitor")

    /// NWPathMonitor cannot be restarted once cancelled, so a fresh instance is created by
    /// every `start()` and released by `stop()`.
    private var monitor: NWPathMonitor?

    private let queue = DispatchQueue(label: "com.neutrino.notes.networkmonitor")

    // MARK: - Init

    /// - Parameter autoStart: pass `false` in unit tests to keep the process free of a live
    ///   path monitor; `setOnlineForTesting(_:)` then drives the published value.
    init(autoStart: Bool = true) {
        if autoStart { start() }
    }

    // MARK: - Lifecycle

    /// Begins observing the system's network path. Safe to call repeatedly.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = (path.status == .satisfied)
            // The handler fires on `queue`; hop to the main actor before publishing.
            Task { @MainActor [weak self] in
                self?.apply(isOnline: online)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        logger.debug("NetworkMonitor started")
    }

    /// Stops observing. Safe to call when not started.
    func stop() {
        guard let monitor else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        self.monitor = nil
        logger.debug("NetworkMonitor stopped")
    }

    // MARK: - Test Hook

    #if DEBUG
    /// Test hook — drives `isOnline` without a real network path.
    func setOnlineForTesting(_ value: Bool) {
        apply(isOnline: value)
    }
    #endif

    // MARK: - Private Helpers

    private func apply(isOnline value: Bool) {
        guard isOnline != value else { return }
        isOnline = value
        logger.debug("connectivity changed: isOnline=\(value, privacy: .public)")
    }
}
