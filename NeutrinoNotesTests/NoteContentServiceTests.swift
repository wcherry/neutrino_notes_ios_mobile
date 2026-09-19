import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoNotes

/// Tests for NoteContentService's crypto helpers (encrypt/decrypt, seal/unsealDEK,
/// encryptMetadata). These exercise the real XChaCha20-Poly1305 secretstream and
/// crypto_box_seal primitives via libsodium — no network involved — mirroring how
/// KeyImportServiceTests exercises real CryptoKit key pairs.
@MainActor
final class NoteContentServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        KeyringTestSupport.clear()
    }

    override func tearDown() {
        super.tearDown()
        KeyringTestSupport.clear()
    }

    // MARK: - Helpers

    /// Installs a real single-version keyring and returns its key pair.
    @discardableResult
    @MainActor
    private func storeRealKeyPair() -> Box.KeyPair {
        KeyringTestSupport.installKeyring()
    }

    // MARK: - encrypt / decrypt round trip

    func test_encryptThenDecrypt_returnsOriginalText() throws {
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        let encrypted = try sut.encrypt(text: "# Hello\n\nWorld", dek: dek, xcss: xcss)
        let decrypted = try sut.decrypt(data: encrypted, dek: dek)

        XCTAssertEqual(decrypted, "# Hello\n\nWorld")
    }

    func test_encryptThenDecrypt_emptyString_roundTrips() throws {
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        let encrypted = try sut.encrypt(text: "", dek: dek, xcss: xcss)
        let decrypted = try sut.decrypt(data: encrypted, dek: dek)

        XCTAssertEqual(decrypted, "")
    }

    func test_decrypt_withWrongDEK_throwsDecryptionFailed() throws {
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let wrongDEK = xcss.key()

        let encrypted = try sut.encrypt(text: "secret note body", dek: dek, xcss: xcss)

        XCTAssertThrowsError(try sut.decrypt(data: encrypted, dek: wrongDEK)) { error in
            guard case NoteContentError.decryptionFailed = error else {
                return XCTFail("Expected decryptionFailed, got \(error)")
            }
        }
    }

    func test_decrypt_withTruncatedData_throwsDecryptionFailed() {
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        XCTAssertThrowsError(try sut.decrypt(data: Data([1, 2, 3]), dek: dek)) { error in
            guard case NoteContentError.decryptionFailed = error else {
                return XCTFail("Expected decryptionFailed, got \(error)")
            }
        }
    }

    // MARK: - sealDEK / unsealDEK round trip

    @MainActor
    func test_sealDEKThenUnseal_returnsOriginalDEK() throws {
        storeRealKeyPair()
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        let sealed = try sut.sealDEK(dek)
        let unsealed = try sut.unsealDEK(sealed.sealed, keyVersion: sealed.keyVersion)

        XCTAssertEqual(unsealed, dek)
    }

    /// Sealing reports which key version it used, so the server can record it on
    /// the key ref and this device can resolve it again later.
    @MainActor
    func test_sealDEK_reportsTheActiveKeyVersion() throws {
        KeyringTestSupport.installRotatedKeyring(versions: 3)
        let sut = NoteContentService()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        XCTAssertEqual(try sut.sealDEK(dek).keyVersion, 3)
    }

    /// The point of keeping retired versions: a note sealed before a rotation
    /// must still open afterwards.
    @MainActor
    func test_unsealDEK_opensADEKSealedToARetiredVersion() throws {
        let pairs = KeyringTestSupport.installRotatedKeyring(versions: 2)
        let sut = NoteContentService()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        // Seal to version 1 by hand — the active version is 2.
        let sealedToV1 = sodium.box.seal(message: dek, recipientPublicKey: pairs[0].publicKey)!
        let b64 = sodium.utils.bin2base64(sealedToV1, variant: .URLSAFE_NO_PADDING)!

        XCTAssertEqual(try sut.unsealDEK(b64, keyVersion: 1), dek)
    }

    /// A version this device does not hold is named, not reported as a bare
    /// decryption failure — the user can act on "restore your recovery kit".
    @MainActor
    func test_unsealDEK_withAnUnknownVersion_namesTheMissingKey() {
        KeyringTestSupport.installKeyring()
        let sut = NoteContentService()

        XCTAssertThrowsError(try sut.unsealDEK("whatever", keyVersion: 4)) { error in
            guard case KeyringError.missingVersion(let version) = error else {
                return XCTFail("Expected KeyringError.missingVersion, got \(error)")
            }
            XCTAssertEqual(version, 4)
        }
    }

    @MainActor
    func test_sealDEK_withNoStoredKeys_throwsNoEncryptionKey() {
        KeyringTestSupport.clear()
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        XCTAssertThrowsError(try sut.sealDEK(dek)) { error in
            guard case NoteContentError.noEncryptionKey = error else {
                return XCTFail("Expected noEncryptionKey, got \(error)")
            }
        }
    }

    func test_unsealDEK_withNoStoredKeys_throwsNoEncryptionKey() {
        let sut = NoteContentService()

        XCTAssertThrowsError(try sut.unsealDEK("anything")) { error in
            guard case NoteContentError.noEncryptionKey = error else {
                return XCTFail("Expected noEncryptionKey, got \(error)")
            }
        }
    }

    // MARK: - encryptMetadata

    func test_encryptMetadata_thenDecrypted_recoversNameAndMimeType() throws {
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        let encryptedMetadata = try sut.encryptMetadata(
            name: "Meeting Notes.md", mimeType: NoteItem.markdownMIME, dek: dek, xcss: xcss
        )

        guard let bytes = sodium.utils.base642bin(encryptedMetadata, variant: .URLSAFE_NO_PADDING) else {
            return XCTFail("encryptMetadata must return valid Base64URL")
        }
        let decryptedJSON = try sut.decrypt(data: Data(bytes), dek: dek)
        let obj = try JSONSerialization.jsonObject(with: Data(decryptedJSON.utf8)) as? [String: String]

        XCTAssertEqual(obj?["name"], "Meeting Notes.md")
        XCTAssertEqual(obj?["mimeType"], NoteItem.markdownMIME)
    }
}
