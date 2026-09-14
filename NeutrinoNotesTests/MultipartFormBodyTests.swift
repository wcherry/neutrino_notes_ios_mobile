import XCTest
import NeutrinoCore
@testable import NeutrinoNotes

/// Tests for the multipart framing shared by note upload, autosave, and version save.
/// Drive's actix-multipart handlers are strict about this shape, and the file part carries
/// ciphertext, so byte-level fidelity matters more than it looks.
final class MultipartFormBodyTests: XCTestCase {

    // MARK: - Helpers

    private func string(_ form: MultipartFormBody) -> String {
        String(decoding: form.finalized(), as: UTF8.self)
    }

    // MARK: - Framing

    func test_contentTypeCarriesTheBoundary() {
        let form = MultipartFormBody(boundary: "abc123")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=abc123")
    }

    func test_defaultBoundariesAreUnique() {
        XCTAssertNotEqual(MultipartFormBody().boundary, MultipartFormBody().boundary)
    }

    func test_emptyBody_isJustTheTerminator() {
        XCTAssertEqual(string(MultipartFormBody(boundary: "B")), "--B--\r\n")
    }

    func test_fieldAndFile_matchTheExpectedWireFormat() {
        var form = MultipartFormBody(boundary: "B")
        form.appendField(name: "label", value: "Before the rewrite")
        form.appendFile(name: "file", fileName: "Notes.md", mimeType: "text/markdown",
                        data: Data("ciphertext".utf8))

        XCTAssertEqual(string(form), """
        --B\r
        Content-Disposition: form-data; name="label"\r
        \r
        Before the rewrite\r
        --B\r
        Content-Disposition: form-data; name="file"; filename="Notes.md"\r
        Content-Type: text/markdown\r
        \r
        ciphertext\r
        --B--\r

        """)
    }

    func test_nilField_isOmittedEntirely() {
        var withNil = MultipartFormBody(boundary: "B")
        withNil.appendField(name: "label", value: nil)
        withNil.appendFile(name: "file", fileName: "n.md", mimeType: "text/plain", data: Data("x".utf8))

        var without = MultipartFormBody(boundary: "B")
        without.appendFile(name: "file", fileName: "n.md", mimeType: "text/plain", data: Data("x".utf8))

        XCTAssertEqual(withNil.finalized(), without.finalized())
    }

    func test_fieldsKeepInsertionOrder() throws {
        var form = MultipartFormBody(boundary: "B")
        form.appendField(name: "encrypted_metadata", value: "meta")
        form.appendField(name: "folder_id", value: "folder-1")
        let body = string(form)

        let metaRange = try XCTUnwrap(body.range(of: "encrypted_metadata"))
        let folderRange = try XCTUnwrap(body.range(of: "folder_id"))
        XCTAssertTrue(metaRange.lowerBound < folderRange.lowerBound)
    }

    // MARK: - Binary safety

    func test_fileBytesSurviveVerbatim() {
        // Ciphertext is not UTF-8; nothing in the builder may re-encode it.
        let bytes = Data((0...255).map { UInt8($0) })
        var form = MultipartFormBody(boundary: "B")
        form.appendFile(name: "file", fileName: "n.md", mimeType: "application/octet-stream", data: bytes)

        let body = form.finalized()
        let header = Data("""
        --B\r
        Content-Disposition: form-data; name="file"; filename="n.md"\r
        Content-Type: application/octet-stream\r
        \r

        """.utf8)
        let expected = header + bytes + Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(body, expected)
    }
}
