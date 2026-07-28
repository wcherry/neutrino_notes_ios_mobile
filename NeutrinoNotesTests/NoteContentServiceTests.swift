import XCTest
import Sodium
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
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        super.tearDown()
        KeyImportService.removeKeys()
    }

    // MARK: - Helpers

    /// Generates a real Curve25519 key pair and stores it in the Keychain under the same
    /// keys KeyImportService uses, base64url-encoded exactly as NoteContentService expects.
    @discardableResult
    private func storeRealKeyPair() -> Box.KeyPair {
        let keyPair = sodium.box.keyPair()!
        let pubB64 = sodium.utils.bin2base64(keyPair.publicKey, variant: .URLSAFE_NO_PADDING)!
        let privB64 = sodium.utils.bin2base64(keyPair.secretKey, variant: .URLSAFE_NO_PADDING)!
        KeychainService.save(pubB64, forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save(privB64, forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1", forKey: KeyImportService.keyVersionKeychainKey)
        return keyPair
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

    func test_sealDEKThenUnseal_returnsOriginalDEK() throws {
        storeRealKeyPair()
        let sut = NoteContentService()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()

        let sealed = try sut.sealDEK(dek)
        let unsealed = try sut.unsealDEK(sealed)

        XCTAssertEqual(unsealed, dek)
    }

    func test_sealDEK_withNoStoredKeys_throwsNoEncryptionKey() {
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
