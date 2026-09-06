import Foundation
import CryptoKit

// MARK: - KeyBundle

struct KeyBundle {
    let publicKey: String
    let privateKey: String
    /// Which keyring version this keypair *is*. The web app's mobile key code
    /// sets it from the entry it exported, so on a rotated account it is not 1.
    /// See `storeKeys(_:userId:)`.
    let keyVersion: String
}

// MARK: - KeyImportError

enum KeyImportError: LocalizedError {
    case invalidJSON
    case missingFields
    case invalidBase64
    case keyPairMismatch
    case unsupportedFormat   // PEM detected

    var errorDescription: String? {
        switch self {
        case .invalidJSON:        return "The file is not valid JSON."
        case .missingFields:      return "The key file is missing required fields."
        case .invalidBase64:      return "One or more keys contain invalid Base64 data."
        case .keyPairMismatch:    return "The public key and private key do not form a matching pair."
        case .unsupportedFormat:  return "PEM-encoded keys are not supported. Please use raw or X9.63 Base64 encoding."
        }
    }
}

// MARK: - KeyImportService

enum KeyImportService {


    // MARK: - importKey

    /// Parse and validate JSON data containing a P-256 key pair.
    /// Throws `KeyImportError` on any validation failure.
    static func importKey(from data: Data) throws -> KeyBundle {
        // Step 1: JSON parse
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KeyImportError.invalidJSON
        }

        // Step 2: Cast and check required fields (accept pk/sk or public_key/private_key)
        guard let dict = parsed as? [String: String] else {
            throw KeyImportError.missingFields
        }
        guard
            let publicKeyString  = dict["public_key"] ?? dict["pk"],
            let privateKeyString = dict["private_key"] ?? dict["sk"]
        else {
            throw KeyImportError.missingFields
        }
        let keyVersionString = dict["key_version"] ?? dict["v"] ?? "1"

        // Step 3: Reject PEM-encoded keys
        if publicKeyString.hasPrefix("-----BEGIN") || privateKeyString.hasPrefix("-----BEGIN") {
            throw KeyImportError.unsupportedFormat
        }

        // Step 4: Normalise Base64URL → standard Base64 and decode
        let pubData  = try decodeBase64(publicKeyString)
        let privData = try decodeBase64(privateKeyString)

        // Steps 5–8: Validate that the public and private keys form a matching pair.
        // Try Curve25519 (X25519 key agreement) first — derive public key from private and compare.
        // Fall back to Curve25519 signing (Ed25519), then P-256.
        guard Self.validateKeyPair(pubData: pubData, privData: privData) else {
            throw KeyImportError.keyPairMismatch
        }

        // Step 9: Return the bundle using the original strings as provided
        return KeyBundle(
            publicKey: publicKeyString,
            privateKey: privateKeyString,
            keyVersion: keyVersionString
        )
    }

    // MARK: - storeKeys

    /// Adopt an imported keypair as this device's keyring and store it.
    ///
    /// Adopted rather than replaced: the imported key is the identity everything
    /// in that account is already sealed to, so minting a fresh one here would
    /// orphan every file.
    ///
    /// `bundle.keyVersion` is honoured, not ignored. It used to be, because the
    /// only thing that set it was the deleted key vault, where the field held
    /// the *envelope format* version — a different quantity that happened to
    /// share the name. The mobile key code sets it from the keyring entry it
    /// exported, so on a rotated account it is the real version and filing the
    /// key under 1 would make every recent note unopenable.
    ///
    /// This installs the active entry only. The account's retired versions come
    /// from `KeyFileService`, which the caller runs next — it needs the key
    /// stored here to open them.
    @MainActor
    @discardableResult
    static func storeKeys(_ bundle: KeyBundle, userId: String) -> Bool {
        guard let publicKey = Base64URL.decode(bundle.publicKey),
              let secretKey = Base64URL.decode(bundle.privateKey)
        else { return false }
        let keyring = KeyringCoder.fromKeyPair(userId: userId,
                                               publicKey: publicKey,
                                               secretKey: secretKey,
                                               version: Int(bundle.keyVersion) ?? 1)
        return KeyringStore.shared.store(keyring)
    }

    // MARK: - hasStoredKeys

    @MainActor
    static func hasStoredKeys() -> Bool {
        KeyringStore.shared.hasKeyring
    }

    // MARK: - removeKeys

    /// Forget this device's keyring. It survives only in the recovery kit or on
    /// another paired device — there is no server copy.
    @MainActor
    static func removeKeys() {
        KeyringStore.shared.clear()
    }

    // MARK: - Private helpers

    /// Returns true if pubData and privData form a valid cryptographic key pair.
    /// Tries Curve25519 key agreement (X25519), Curve25519 signing (Ed25519), and P-256 in order.
    private static func validateKeyPair(pubData: Data, privData: Data) -> Bool {
        // X25519: derive public key from private and compare directly.
        // Note: constructing a Curve25519 key never throws for any 32-byte
        // input (raw keys are just clamped scalars), so a non-matching result
        // here must fall through to the other key types rather than return
        // false immediately.
        if let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privData),
           priv.publicKey.rawRepresentation == pubData {
            return true
        }
        // Ed25519: same approach.
        if let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData),
           priv.publicKey.rawRepresentation == pubData {
            return true
        }
        // P-256: sign a test payload and verify with the public key.
        let p256priv = (try? P256.Signing.PrivateKey(rawRepresentation: privData))
                    ?? (try? P256.Signing.PrivateKey(x963Representation: privData))
        let p256pub  = (try? P256.Signing.PublicKey(rawRepresentation: pubData))
                    ?? (try? P256.Signing.PublicKey(x963Representation: pubData))
        if let priv = p256priv, let pub = p256pub,
           let sig = try? priv.signature(for: Data("neutrino-key-validation".utf8)) {
            return pub.isValidSignature(sig, for: Data("neutrino-key-validation".utf8))
        }
        return false
    }

    /// Convert Base64URL to standard Base64, then decode to Data.
    /// Throws `KeyImportError.invalidBase64` if decoding fails.
    private static func decodeBase64(_ input: String) throws -> Data {
        // Replace Base64URL characters with standard Base64 characters
        var standard = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding to reach a multiple of 4
        let remainder = standard.count % 4
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }

        guard let decoded = Data(base64Encoded: standard) else {
            throw KeyImportError.invalidBase64
        }
        return decoded
    }
}
