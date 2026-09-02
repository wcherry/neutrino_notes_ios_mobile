import XCTest
import CommonCrypto
import Sodium
@testable import NeutrinoNotes

// MARK: - KeyQRDecryptServiceTests
//
// The key code is the only path by which a key reaches this app from the web,
// so its envelope has to match `web/packages/e2e-crypto/src/mobileKeyQr.ts`
// byte for byte. There is no phone in the loop here: the tests build the
// envelope exactly as the web side does — PBKDF2-SHA256 over the PIN, then a
// libsodium secretbox — and check this opens it.
//
// The iteration count is deliberately low in the fixtures. 600 000 is the real
// value and is what the app uses; running it per test would add seconds to the
// suite to re-prove a number that is asserted directly instead.

final class KeyQRDecryptServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Building an envelope the way the web app does

    private func pbkdf2(pin: String, salt: Data, iterations: Int) -> Data {
        var derived = Data(repeating: 0, count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                Data(pin.utf8).withUnsafeBytes { pinBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pin.utf8.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32)
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        return derived
    }

    private func envelope(payload: String,
                          pin: String,
                          iterations: Int = 1_000,
                          includeIterations: Bool = true,
                          alg: String = "pbkdf2-sha256+xsalsa20",
                          version: Int = 1) -> String {
        let salt = sodium.randomBytes.buf(length: 16)!
        let nonce = sodium.randomBytes.buf(length: sodium.secretBox.NonceBytes)!
        let key = Array(pbkdf2(pin: pin, salt: Data(salt), iterations: iterations))
        // `seal` returns the combined MAC||ciphertext form, which is what the web side's
        // `crypto_secretbox_easy` writes and what the service expects.
        let ct = sodium.secretBox.seal(message: Array(payload.utf8), secretKey: key, nonce: nonce)!

        var fields = [
            "\"v\":\(version)",
            "\"alg\":\"\(alg)\"",
            "\"salt\":\"\(Base64URL.encode(salt))\"",
            "\"nonce\":\"\(Base64URL.encode(nonce))\"",
            "\"ct\":\"\(Base64URL.encode(ct))\""
        ]
        if includeIterations { fields.append("\"iter\":\(iterations)") }
        return "{\(fields.joined(separator: ","))}"
    }

    /// The inner JSON the web side puts in the envelope. Every field is a string, including
    /// `key_version` — a numeric one makes `KeyImportService`'s `[String: String]` cast fail with
    /// "missing fields", which is why `mobileKeyQr.ts` stringifies it.
    private func keyPayload(_ pair: Box.KeyPair, version: Int) -> String {
        """
        {"public_key":"\(Base64URL.encode(pair.publicKey))",\
        "private_key":"\(Base64URL.encode(pair.secretKey))",\
        "key_version":"\(version)"}
        """
    }

    // MARK: - Round trip

    func testOpensAnEnvelopeBuiltTheWayTheWebAppBuildsOne() throws {
        let pair = sodium.box.keyPair()!
        let payload = keyPayload(pair, version: 3)

        let opened = try KeyQRDecryptService.decrypt(qrString: envelope(payload: payload, pin: "123456"),
                                                     pin: "123456")

        XCTAssertEqual(String(decoding: opened, as: UTF8.self), payload)
    }

    /// The point of the whole path: what comes out is a key this app can install, at the version
    /// the code says it is.
    func testTheDecryptedPayloadImportsAsAKeyBundle() throws {
        let pair = sodium.box.keyPair()!
        let opened = try KeyQRDecryptService.decrypt(
            qrString: envelope(payload: keyPayload(pair, version: 4), pin: "654321"),
            pin: "654321")

        let bundle = try KeyImportService.importKey(from: opened)

        XCTAssertEqual(Base64URL.decode(bundle.publicKey), pair.publicKey)
        XCTAssertEqual(Base64URL.decode(bundle.privateKey), pair.secretKey)
        XCTAssertEqual(bundle.keyVersion, "4", "a rotated account's code is not version 1")
    }

    /// An older web build omits `iter`. It used 600 000, so the fallback has to be that number and
    /// not a smaller one that would derive a different key.
    func testFallsBackToSixHundredThousandIterationsWhenIterIsAbsent() throws {
        XCTAssertEqual(KeyQRDecryptService.defaultIterations, 600_000)

        let payload = #"{"public_key":"a","private_key":"b","key_version":"1"}"#
        let qr = envelope(payload: payload, pin: "000000",
                          iterations: KeyQRDecryptService.defaultIterations,
                          includeIterations: false)

        XCTAssertEqual(String(decoding: try KeyQRDecryptService.decrypt(qrString: qr, pin: "000000"),
                              as: UTF8.self),
                       payload)
    }

    // MARK: - Refusals

    func testAWrongPinIsReportedAsSuch() {
        let qr = envelope(payload: #"{"a":"b"}"#, pin: "111111")

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "222222")) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("expected decryptionFailure, got \(error)")
            }
        }
    }

    func testAnUnknownAlgorithmIsRefusedRatherThanGuessed() {
        let qr = envelope(payload: #"{"a":"b"}"#, pin: "111111", alg: "pbkdf2-sha512+aes")

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "111111")) { error in
            guard case KeyQRDecryptError.unsupportedAlgorithm = error else {
                return XCTFail("expected unsupportedAlgorithm, got \(error)")
            }
        }
    }

    func testANewerEnvelopeVersionIsRefused() {
        let qr = envelope(payload: #"{"a":"b"}"#, pin: "111111", version: 2)

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "111111")) { error in
            guard case KeyQRDecryptError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    /// Scanning the wrong QR code is the most likely mistake a user makes here, so the error names
    /// what was scanned rather than reporting a crypto failure.
    func testScanningSomethingThatIsNotAKeyCodeSaysSo() {
        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: "https://example.com", pin: "111111")
        ) { error in
            guard case KeyQRDecryptError.invalidQRFormat(let raw) = error else {
                return XCTFail("expected invalidQRFormat, got \(error)")
            }
            XCTAssertEqual(raw, "https://example.com")
        }
    }
}
