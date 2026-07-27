import XCTest
import CryptoKit
import CommonCrypto
import Foundation
import Sodium
@testable import NeutrinoNotes

/// Tests for KeyQRDecryptService.
///
/// The `makeQRString` helper performs genuine PBKDF2-SHA256 key derivation and
/// XSalsa20-Poly1305 encryption using swift-sodium, mirroring the protocol
/// implemented by `KeyQRDecryptService.decrypt`, so the happy-path test
/// exercises a real cryptographic round-trip rather than mocked data.
final class KeyQRDecryptServiceTests: XCTestCase {

    // MARK: - Helpers

    private let sodium = Sodium()

    /// Generates a real P-256 key pair and returns its fields serialised as a
    /// JSON string: `{ "public_key": "<x963-base64>", "private_key":
    /// "<raw-base64>", "key_version": "1" }`.
    private func makeKeyPairJSON() -> String {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey  = privateKey.publicKey
        let pubB64  = publicKey.x963Representation.base64EncodedString()
        let privB64 = privateKey.rawRepresentation.base64EncodedString()
        let dict: [String: String] = [
            "public_key":  pubB64,
            "private_key": privB64,
            "key_version": "1",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        return String(data: data, encoding: .utf8)!
    }

    /// Encrypts `plaintextJSON` under `pin` using the same protocol that
    /// `KeyQRDecryptService.decrypt` must reverse, and returns the outer QR
    /// JSON string ready to be passed to the service.
    ///
    /// Protocol:
    ///   1. Derive a 32-byte key from `pin` + random 16-byte salt via PBKDF2-SHA256.
    ///   2. Seal `plaintextJSON` (UTF-8 bytes) with XSalsa20-Poly1305 (NaCl
    ///      secretBox) using a random 24-byte nonce.
    ///   3. Return `{ "v": 1, "alg": "pbkdf2-sha256+xsalsa20", "salt": b64url,
    ///      "nonce": b64url, "ct": b64url, "iter": <iterations> }`.
    private func makeQRString(plaintextJSON: String, pin: String, iterations: Int = 1000) -> String {
        let saltData  = Data(sodium.randomBytes.buf(length: 16)!)
        let nonceData = Data(sodium.randomBytes.buf(length: 24)!)

        let key = pbkdf2SHA256(password: pin, salt: saltData, iterations: iterations, keyLength: 32)

        let messageBytes = Array(plaintextJSON.utf8)
        guard let cipherBytes = sodium.secretBox.seal(
            message: messageBytes,
            secretKey: Array(key),
            nonce: Array(nonceData)
        ) else {
            XCTFail("XSalsa20-Poly1305 encryption failed in test helper")
            return "{}"
        }

        let outerDict: [String: Any] = [
            "v":     1,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  base64URL(saltData),
            "nonce": base64URL(nonceData),
            "ct":    base64URL(Data(cipherBytes)),
            "iter":  iterations,
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outerDict)
        return String(data: outerData, encoding: .utf8)!
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(repeating: 0, count: keyLength)

        _ = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return derivedKey
    }

    // MARK: - Happy Path

    /// A valid QR string encrypted with the correct PIN must return Data that
    /// deserialises to a JSON object containing `public_key`, `private_key`,
    /// and `key_version` — matching the plaintext that was originally encrypted.
    ///
    /// This test performs a genuine PBKDF2-SHA256 + XSalsa20-Poly1305 round-trip.
    func test_decrypt_withValidQRAndCorrectPIN_returnsKeyPairData() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString      = makeQRString(plaintextJSON: plaintextJSON, pin: "test-pin-1234")

        let resultData = try KeyQRDecryptService.decrypt(qrString: qrString, pin: "test-pin-1234")

        guard let parsed = try JSONSerialization.jsonObject(with: resultData) as? [String: String] else {
            XCTFail("Decrypted data did not parse as [String: String] JSON object")
            return
        }
        XCTAssertNotNil(parsed["public_key"],  "public_key must be present in decrypted JSON")
        XCTAssertNotNil(parsed["private_key"], "private_key must be present in decrypted JSON")
        XCTAssertNotNil(parsed["key_version"], "key_version must be present in decrypted JSON")

        // Verify the round-trip is byte-for-byte identical to the original.
        XCTAssertEqual(resultData, Data(plaintextJSON.utf8))
    }

    // MARK: - Wrong PIN

    /// Passing a PIN that differs from the one used to encrypt must cause
    /// decryption to fail with `KeyQRDecryptError.decryptionFailure`. PBKDF2
    /// will derive a different key, so the Poly1305 tag will not verify.
    func test_decrypt_withWrongPIN_throwsDecryptionFailure() {
        let qrString = makeQRString(plaintextJSON: makeKeyPairJSON(), pin: "correct-pin")

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "wrong-pin")
        ) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.decryptionFailure, got \(error)")
            }
        }
    }

    // MARK: - Malformed Payload

    /// When one of the base64url-encoded fields in the outer QR JSON is not
    /// valid Base64, the service must throw
    /// `KeyQRDecryptError.base64DecodeFailure` before attempting any
    /// cryptographic operation.
    func test_decrypt_withInvalidBase64Field_throwsBase64DecodeFailure() {
        let outerDict: [String: Any] = [
            "v":     1,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  "not valid base64!!!",
            "nonce": "dGVzdA",
            "ct":    "dGVzdA",
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.base64DecodeFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.base64DecodeFailure, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Version

    /// A QR JSON where `v` is not `1` must throw
    /// `KeyQRDecryptError.unsupportedVersion` immediately, before any attempt
    /// to decode the payload or derive a key.
    func test_decrypt_withUnsupportedVersion_throwsUnsupportedVersion() {
        let outerDict: [String: Any] = [
            "v":     99,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  "dGVzdA",
            "nonce": "dGVzdA",
            "ct":    "dGVzdA",
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedVersion = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedVersion, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Algorithm

    /// A QR JSON where `alg` is a value other than `"pbkdf2-sha256+xsalsa20"`
    /// must throw `KeyQRDecryptError.unsupportedAlgorithm`, giving callers a
    /// clear signal to upgrade the app rather than silently corrupting data.
    func test_decrypt_withUnsupportedAlgorithm_throwsUnsupportedAlgorithm() {
        let outerDict: [String: Any] = [
            "v":     1,
            "alg":   "aes-gcm",
            "salt":  "dGVzdA",
            "nonce": "dGVzdA",
            "ct":    "dGVzdA",
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedAlgorithm = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedAlgorithm, got \(error)")
            }
        }
    }

    // MARK: - Garbage QR String

    /// A string that is not JSON at all must throw
    /// `KeyQRDecryptError.invalidQRFormat`. This covers the case where a
    /// non-Neutrino QR code is accidentally scanned.
    func test_decrypt_withGarbageQRString_throwsInvalidQRFormat() {
        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: "not json at all", pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.invalidQRFormat = error else {
                return XCTFail("Expected KeyQRDecryptError.invalidQRFormat, got \(error)")
            }
        }
    }
}
