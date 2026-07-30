import XCTest
@testable import NeutrinoNotes

/// Tests for `SyncPersistence`'s on-disk queue/watermark storage. Exercises real file I/O
/// against a fresh, per-test temporary directory (never the real Application Support path
/// used by `.shared`), matching how this component is actually exercised in the app.
@MainActor
final class SyncPersistenceTests: XCTestCase {

    // MARK: - Lifecycle

    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        // Deliberately not created on disk here — SyncPersistence itself must create the
        // directory lazily on first save; tests never call mkdir themselves.
        tempDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        if let tempDirectoryURL, FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEntry(itemID: String) -> SyncQueueEntry {
        SyncQueueEntry.renameFile(itemID: itemID, newName: "New Name", previousName: "Old Name")
    }

    // MARK: - loadQueue on a fresh directory

    func test_loadQueue_freshDirectory_returnsEmptyArray() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)

        XCTAssertEqual(sut.loadQueue(), [])
    }

    // MARK: - saveQueue / loadQueue round trip

    func test_saveQueueThenLoadQueue_roundTripsEntriesExactly() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)
        let entries = [makeEntry(itemID: "f1"), makeEntry(itemID: "f2")]

        sut.saveQueue(entries)

        XCTAssertEqual(sut.loadQueue(), entries)
    }

    func test_saveQueue_calledTwice_overwritesRatherThanAppending() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)
        let first = [makeEntry(itemID: "a")]
        let second = [makeEntry(itemID: "b")]

        sut.saveQueue(first)
        sut.saveQueue(second)

        XCTAssertEqual(sut.loadQueue(), second)
    }

    func test_saveQueue_directoryDoesNotExistYet_createsItRatherThanFailing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectoryURL.path),
                        "Precondition: the directory must not exist before SyncPersistence touches it")
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)

        sut.saveQueue([makeEntry(itemID: "f1")])

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: tempDirectoryURL.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue)
    }

    // MARK: - loadWatermarks on a fresh directory

    func test_loadWatermarks_freshDirectory_returnsEmptyDictionary() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)

        XCTAssertEqual(sut.loadWatermarks(), [:])
    }

    // MARK: - saveWatermarks / loadWatermarks round trip

    func test_saveWatermarksThenLoadWatermarks_roundTripsExactly() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)
        let watermarks: [String: Date] = [
            "item-1": Date(timeIntervalSince1970: 1_700_000_000),
            "item-2": Date(timeIntervalSince1970: 1_700_000_500),
        ]

        sut.saveWatermarks(watermarks)

        XCTAssertEqual(sut.loadWatermarks(), watermarks)
    }

    func test_saveWatermarks_calledTwice_overwritesRatherThanAppending() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)
        sut.saveWatermarks(["a": Date(timeIntervalSince1970: 0)])
        sut.saveWatermarks(["b": Date(timeIntervalSince1970: 1)])

        XCTAssertEqual(sut.loadWatermarks(), ["b": Date(timeIntervalSince1970: 1)])
    }

    func test_saveWatermarks_directoryDoesNotExistYet_createsItRatherThanFailing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectoryURL.path),
                        "Precondition: the directory must not exist before SyncPersistence touches it")
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)

        sut.saveWatermarks(["item-1": Date(timeIntervalSince1970: 1_700_000_000)])

        XCTAssertEqual(sut.loadWatermarks(), ["item-1": Date(timeIntervalSince1970: 1_700_000_000)])
    }

    // MARK: - Independence of queue and watermark storage

    func test_saveQueue_doesNotAffectWatermarks() {
        let sut = SyncPersistence(directoryURL: tempDirectoryURL)
        sut.saveWatermarks(["item-1": Date(timeIntervalSince1970: 1_700_000_000)])

        sut.saveQueue([makeEntry(itemID: "f1")])

        XCTAssertEqual(sut.loadWatermarks(), ["item-1": Date(timeIntervalSince1970: 1_700_000_000)])
    }
}
