import UIKit
import BackgroundTasks
import os.log

// MARK: - AppDelegate

/// Registers and drives the `BGProcessingTask` that runs `SyncEngine.shared.runSync()` in the
/// background. `BGProcessingTask` (not `BGAppRefreshTask`) because draining a queue of
/// encrypted-body uploads/downloads and running delta sync can legitimately run longer than a
/// refresh-task budget allows — this is exactly Apple's documented "upload/download... may take
/// minutes" use case.
///
/// Registration must happen synchronously in `didFinishLaunchingWithOptions`, before it
/// returns, per Apple's requirement — it cannot be deferred behind SwiftUI's view lifecycle
/// (hence a real `AppDelegate` via `@UIApplicationDelegateAdaptor` rather than doing this from
/// a `.task` modifier), and it must be unconditional: only *submitting* a request is gated
/// behind `FeatureFlags.syncEngine` (see `scheduleNext()`), never registering the handler.
final class AppDelegate: NSObject, UIApplicationDelegate {

    static let taskIdentifier = "com.neutrino.notes.sync"

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            Self.handle(task: task)
        }
        return true
    }

    // MARK: - Task Handling

    private static func handle(task: BGTask) {
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        let completion = CompletionOnce(task: processingTask)

        let syncTask = Task {
            await SyncEngine.shared.runSync()
            completion.complete(success: true)
            scheduleNext()
        }

        processingTask.expirationHandler = {
            syncTask.cancel()
            completion.complete(success: false)
        }
    }

    // MARK: - Scheduling

    /// Submits the next background sync request. Called after each foreground `runSync()`
    /// completes and when the scene backgrounds, so there's always a next attempt scheduled —
    /// gated behind `FeatureFlags.syncEngine` (submission only; `register` above stays
    /// unconditional).
    static func scheduleNext() {
        guard FeatureFlags.syncEngine else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("scheduleNext: submit failed: \(error, privacy: .public)")
        }
    }
}

// MARK: - CompletionOnce

/// Guards against calling `setTaskCompleted(success:)` twice (once from the expiration handler,
/// once from normal completion racing it) — iOS logs a warning if it's called more than once
/// for the same task.
private final class CompletionOnce {
    private let task: BGProcessingTask
    private let lock = NSLock()
    private var didComplete = false

    init(task: BGProcessingTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return }
        didComplete = true
        task.setTaskCompleted(success: success)
    }
}
