import XCTest
@testable import NeutrinoNotes

/// Tests for the shared Drive timestamp parser. Drive emits zone-less `NaiveDateTime` strings
/// from its file endpoints and zoned RFC 3339 strings from its version endpoints, with a
/// fractional-digit count that varies with the value, so this is the one place that has to
/// cope with all of it.
final class DriveDateTests: XCTestCase {

    // MARK: - Reference

    /// 2026-07-30T14:25:36Z
    private var reference: Date {
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

    // MARK: - Fractional digits

    func test_parsesEveryFractionalDigitCountChronoEmits() {
        // chrono's AutoSi serialization uses 0, 3, 6, or 9 digits depending on the value.
        for raw in ["2026-07-30T14:25:36Z",
                    "2026-07-30T14:25:36.000Z",
                    "2026-07-30T14:25:36.000000Z",
                    "2026-07-30T14:25:36.000000000Z"] {
            XCTAssertEqual(DriveDate.date(from: raw), reference, "failed on \(raw)")
        }
    }

    func test_fractionalSecondsAreValuedConsistentlyRegardlessOfPrecision() {
        // Half a second is half a second whether it's written with 3, 6, or 9 digits — the
        // bug this guards against is reading ".500000" as 500 000 milliseconds.
        for raw in ["2026-07-30T14:25:36.500Z",
                    "2026-07-30T14:25:36.500000Z",
                    "2026-07-30T14:25:36.500000000Z",
                    "2026-07-30T14:25:36.500000"] {
            let date = DriveDate.date(from: raw)
            XCTAssertNotNil(date, "failed on \(raw)")
            XCTAssertEqual(date!.timeIntervalSince(reference), 0.5, accuracy: 0.0005, "failed on \(raw)")
        }
    }

    func test_subMillisecondPrecisionIsTruncatedNotMisread() {
        let date = DriveDate.date(from: "2026-07-30T14:25:36.123999Z")
        XCTAssertEqual(date?.timeIntervalSince(reference) ?? -1, 0.123, accuracy: 0.0005)
    }

    // MARK: - Zones

    func test_zonelessTimestampsAreReadAsUTC() {
        XCTAssertEqual(DriveDate.date(from: "2026-07-30T14:25:36"), reference)
        XCTAssertEqual(DriveDate.date(from: "2026-07-30T14:25:36.000000"), reference)
    }

    func test_parsesExplicitOffsets() {
        XCTAssertEqual(DriveDate.date(from: "2026-07-30T14:25:36+00:00"), reference)
        // 16:25:36+02:00 is the same instant as 14:25:36Z.
        XCTAssertEqual(DriveDate.date(from: "2026-07-30T16:25:36+02:00"), reference)
        XCTAssertEqual(DriveDate.date(from: "2026-07-30T09:25:36-05:00"), reference)
    }

    func test_dateHyphensAreNotMistakenForAZoneOffset() throws {
        // The naive shape contains two hyphens; only an offset past the date part counts. Were
        // one of them read as a zone, the instant would be hours off, not fractions of a second.
        let date = try XCTUnwrap(DriveDate.date(from: "2026-07-30T14:25:36.123456"))
        XCTAssertEqual(date.timeIntervalSince(reference), 0.123, accuracy: 0.0005)
    }

    // MARK: - Rejections

    func test_rejectsUnparseableInput() {
        for raw in ["", "30 July 2026", "2026-07-30", "not a date at all", "2026-07-30T14:25:36.12x456Z"] {
            XCTAssertNil(DriveDate.date(from: raw), "should not have parsed \(raw)")
        }
    }

    // MARK: - Decoder

    func test_decoderAppliesTheParserAndReportsFailures() throws {
        struct Payload: Decodable { let updatedAt: Date }

        var failures: [String] = []
        let decoder = DriveDate.makeDecoder(convertFromSnakeCase: true) { failures.append($0) }

        let ok = try decoder.decode(Payload.self, from: Data(#"{"updated_at":"2026-07-30T14:25:36Z"}"#.utf8))
        XCTAssertEqual(ok.updatedAt, reference)
        XCTAssertTrue(failures.isEmpty)

        XCTAssertThrowsError(try decoder.decode(Payload.self, from: Data(#"{"updated_at":"nope"}"#.utf8)))
        XCTAssertEqual(failures, ["nope"])
    }
}
