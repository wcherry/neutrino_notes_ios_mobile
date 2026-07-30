import XCTest
@testable import NeutrinoNotes

/// Tests for decoding Drive's version payloads. The versions endpoint serializes `createdAt`
/// as a chrono `DateTime<Utc>` (RFC 3339, `Z`, with 0/3/6/9 fractional digits depending on the
/// value), unlike the naive, zone-less timestamps the file endpoints return — so all of those
/// shapes have to decode, or version history breaks on nothing more than a round number of
/// microseconds.
final class NoteVersionTests: XCTestCase {

    // MARK: - Helpers

    private func json(createdAt: String) -> Data {
        Data("""
        {
          "id": "ver-1",
          "fileId": "file-1",
          "versionNumber": 3,
          "sizeBytes": 2048,
          "label": "Before the rewrite",
          "createdAt": "\(createdAt)",
          "isNamed": true
        }
        """.utf8)
    }

    private func decode(createdAt: String) throws -> NoteVersion {
        try NoteVersion.decoder.decode(NoteVersion.self, from: json(createdAt: createdAt))
    }

    /// 2026-07-30T14:25:36Z
    private var expectedSeconds: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 30
        components.hour = 14
        components.minute = 25
        components.second = 36
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    // MARK: - Fields

    func test_decodesAllFields() throws {
        let version = try decode(createdAt: "2026-07-30T14:25:36Z")

        XCTAssertEqual(version.id, "ver-1")
        XCTAssertEqual(version.fileID, "file-1")
        XCTAssertEqual(version.versionNumber, 3)
        XCTAssertEqual(version.sizeBytes, 2048)
        XCTAssertEqual(version.label, "Before the rewrite")
        XCTAssertTrue(version.isNamed)
        XCTAssertEqual(version.createdAt, expectedSeconds)
    }

    func test_decodesNullLabel() throws {
        let data = Data("""
        {"id":"v","fileId":"f","versionNumber":1,"sizeBytes":0,"label":null,
         "createdAt":"2026-07-30T14:25:36Z","isNamed":false}
        """.utf8)
        let version = try NoteVersion.decoder.decode(NoteVersion.self, from: data)

        XCTAssertNil(version.label)
        XCTAssertFalse(version.isNamed)
    }

    // MARK: - Date shapes

    func test_decodesZonedWholeSeconds() throws {
        XCTAssertEqual(try decode(createdAt: "2026-07-30T14:25:36Z").createdAt, expectedSeconds)
    }

    func test_decodesZonedMilliseconds() throws {
        let date = try decode(createdAt: "2026-07-30T14:25:36.500Z").createdAt
        XCTAssertEqual(date.timeIntervalSince(expectedSeconds), 0.5, accuracy: 0.001)
    }

    func test_decodesZonedMicroseconds() throws {
        let date = try decode(createdAt: "2026-07-30T14:25:36.500000Z").createdAt
        XCTAssertEqual(date.timeIntervalSince(expectedSeconds), 0.5, accuracy: 0.001)
    }

    func test_decodesZonedNanoseconds() throws {
        let date = try decode(createdAt: "2026-07-30T14:25:36.500000000Z").createdAt
        XCTAssertEqual(date.timeIntervalSince(expectedSeconds), 0.5, accuracy: 0.001)
    }

    func test_decodesExplicitUTCOffset() throws {
        XCTAssertEqual(try decode(createdAt: "2026-07-30T14:25:36+00:00").createdAt, expectedSeconds)
    }

    func test_decodesNaiveTimestampsAsUTC() throws {
        // The restore endpoint returns file metadata, whose timestamps carry no zone.
        XCTAssertEqual(try decode(createdAt: "2026-07-30T14:25:36").createdAt, expectedSeconds)
        XCTAssertEqual(try decode(createdAt: "2026-07-30T14:25:36.000000").createdAt, expectedSeconds)
    }

    func test_unparseableDate_throws() {
        XCTAssertThrowsError(try decode(createdAt: "30 July 2026"))
    }

    // MARK: - Display

    func test_displayTitle_usesLabelWhenPresent() throws {
        let version = try decode(createdAt: "2026-07-30T14:25:36Z")
        XCTAssertEqual(version.displayTitle, "Before the rewrite (v3)")
        XCTAssertEqual(version.shortTitle, "v3")
    }

    func test_displayTitle_fallsBackToVersionNumber() throws {
        for label in ["null", "\"\"", "\"   \""] {
            let data = Data("""
            {"id":"v","fileId":"f","versionNumber":7,"sizeBytes":0,"label":\(label),
             "createdAt":"2026-07-30T14:25:36Z","isNamed":false}
            """.utf8)
            let version = try NoteVersion.decoder.decode(NoteVersion.self, from: data)
            XCTAssertEqual(version.displayTitle, "Version 7", "label was \(label)")
        }
    }
}
