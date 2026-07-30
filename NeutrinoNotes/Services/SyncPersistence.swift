import Foundation
import os.log

// MARK: - SyncPersistence

/// Durable on-disk storage for the sync retry queue and per-item watermark map — plain JSON
/// files under Application Support, written atomically. This is the actual source of truth
/// `SyncEngine` reloads from at launch and writes to after every queue mutation, so a queued
/// mutation survives an app relaunch or a background-task kill.
///
/// No CoreData/SwiftData: this app's floor is iOS 16 (SwiftData is 17+), and nothing here
/// justifies that weight — a lightweight FileManager-based store, the same style already used
/// elsewhere in this app (see `KeychainService`).
final class SyncPersistence {

    // MARK: - Shared

    static let shared: SyncPersistence = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("NeutrinoNotesSync", isDirectory: true)
        return SyncPersistence(directoryURL: directory)
    }()

    // MARK: - Files

    private let directoryURL: URL
    private var queueURL: URL { directoryURL.appendingPathComponent("queue.json") }
    private var watermarksURL: URL { directoryURL.appendingPathComponent("watermarks.json") }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "SyncPersistence")

    // MARK: - Init

    /// Deliberately does NOT create `directoryURL` on disk — the directory is created lazily
    /// on first save, so simply constructing this type (including `.shared`, at process launch)
    /// never touches the filesystem.
    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    // MARK: - Queue

    func loadQueue() -> [SyncQueueEntry] {
        load(from: queueURL) ?? []
    }

    func saveQueue(_ entries: [SyncQueueEntry]) {
        save(entries, to: queueURL)
    }

    // MARK: - Watermarks

    func loadWatermarks() -> [String: Date] {
        load(from: watermarksURL) ?? [:]
    }

    func saveWatermarks(_ watermarks: [String: Date]) {
        save(watermarks, to: watermarksURL)
    }

    // MARK: - Private I/O

    /// Returns `nil` (never throws/crashes) if the file doesn't exist yet or fails to decode —
    /// callers treat `nil` as "nothing persisted yet" and fall back to an empty collection.
    private func load<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("load failed at \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Full overwrite (not append), written atomically so a crash mid-write can't corrupt the
    /// file into a half-written state.
    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try ensureDirectoryExists()
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("save failed at \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func ensureDirectoryExists() throws {
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        // Transient retry cache, not user data of record (the server is the source of truth) —
        // excluded from iCloud/iTunes backup.
        var excludable = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludable.setResourceValues(resourceValues)
    }
}
