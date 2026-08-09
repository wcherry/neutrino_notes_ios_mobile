import XCTest
@testable import NeutrinoNotes

/// Tests for the file-events wire format and socket addressing.
///
/// The framing is shared with the server (`src/shared/collab_protocol.rs`) and the web client, so
/// these are interop tests: a frame this app writes has to be one the relay will forward, and one
/// the relay forwards has to be one this app can read.
@MainActor
final class FileEventsClientTests: XCTestCase {

    // MARK: - Varint

    func test_varint_roundTripsTheValuesTheProtocolUses() {
        for value in [0, 1, 2, 127, 128, 300, 16_384, 1_000_000] {
            var data = Data()
            FileEventsMessage.writeVarint(value, into: &data)
            let decoded = FileEventsMessage.readVarint(data)
            XCTAssertEqual(decoded?.value, value, "value \(value)")
            XCTAssertEqual(decoded?.next, data.count, "value \(value)")
        }
    }

    func test_varint_singleByteForSmallValues() {
        var data = Data()
        FileEventsMessage.writeVarint(2, into: &data)
        XCTAssertEqual(Array(data), [2])
    }

    func test_varint_truncatedInputDecodesToNilRatherThanTrapping() {
        // 0x80 says "another byte follows" and there isn't one — a half-frame off a socket.
        XCTAssertNil(FileEventsMessage.readVarint(Data([0x80])))
        XCTAssertNil(FileEventsMessage.readVarint(Data()))
    }

    // MARK: - Frames

    func test_encodeFileUpdated_isTypeTwoFollowedByTheSenderJSON() {
        let frame = FileEventsMessage.encodeFileUpdated(clientID: "abc123")
        XCTAssertEqual(frame.first, UInt8(FileEventsMessage.fileUpdated))
        XCTAssertEqual(String(data: frame.dropFirst(), encoding: .utf8), #"{"clientId":"abc123"}"#)
    }

    func test_decode_readsBackWhatEncodeWrote() {
        let frame = FileEventsMessage.encodeFileUpdated(clientID: "abc123")
        XCTAssertEqual(FileEventsMessage.decodeFileUpdatedSender(frame), "abc123")
    }

    func test_decode_ignoresAwarenessFrames() {
        // Type 1 is presence, which this app doesn't draw. Reading it as an update would reload the
        // note every time somebody merely opened it.
        var frame = Data()
        FileEventsMessage.writeVarint(FileEventsMessage.awareness, into: &frame)
        frame.append(contentsOf: Array(#"{"clientId":"abc123"}"#.utf8))
        XCTAssertNil(FileEventsMessage.decodeFileUpdatedSender(frame))
    }

    func test_decode_ignoresGarbageAndEmptyPayloads() {
        var typeOnly = Data()
        FileEventsMessage.writeVarint(FileEventsMessage.fileUpdated, into: &typeOnly)
        XCTAssertNil(FileEventsMessage.decodeFileUpdatedSender(typeOnly))

        var notJSON = typeOnly
        notJSON.append(contentsOf: Array("not json".utf8))
        XCTAssertNil(FileEventsMessage.decodeFileUpdatedSender(notJSON))

        XCTAssertNil(FileEventsMessage.decodeFileUpdatedSender(Data()))
    }

    func test_ownFrameIsDistinguishableFromAPeersFrame() {
        // The relay echoes to every session in the room, including the sender. Without this the
        // editor would reload the note it just saved, every time it saved it.
        let mine = FileEventsClient(clientID: "me")
        XCTAssertEqual(FileEventsMessage.decodeFileUpdatedSender(
            FileEventsMessage.encodeFileUpdated(clientID: mine.clientID)), "me")
        XCTAssertNotEqual(FileEventsMessage.decodeFileUpdatedSender(
            FileEventsMessage.encodeFileUpdated(clientID: "someone-else")), mine.clientID)
    }

    // MARK: - Socket URL

    func test_socketURL_upgradesHTTPSToWSS() {
        XCTAssertEqual(
            FileEventsClient.socketURL(fileID: "f1", token: "t", baseURL: "https://www.getneutrino.app")?
                .absoluteString,
            "wss://www.getneutrino.app/api/v1/files/f1/ws?token=t"
        )
    }

    func test_socketURL_upgradesHTTPToWSForADevelopmentServer() {
        XCTAssertEqual(
            FileEventsClient.socketURL(fileID: "f1", token: "t", baseURL: "http://localhost:8080")?
                .absoluteString,
            "ws://localhost:8080/api/v1/files/f1/ws?token=t"
        )
    }

    func test_socketURL_sendsTheTokenVerbatim() {
        // The server slices the token out of the raw query string and never percent-decodes it, so
        // escaping here would hand it a token that doesn't validate. A JWT is base64url, so there
        // is nothing to escape — but this pins the requirement, because "helpfully" encoding it is
        // exactly what a URL builder does by default.
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1LTEifQ.sig-with_chars"
        let url = FileEventsClient.socketURL(fileID: "f1", token: token, baseURL: "https://example.com")
        XCTAssertEqual(url?.absoluteString, "wss://example.com/api/v1/files/f1/ws?token=\(token)")
    }

    func test_socketURL_refusesAHostItCannotUpgrade() {
        XCTAssertNil(FileEventsClient.socketURL(fileID: "f1", token: "t", baseURL: "ftp://example.com"))
    }
}
