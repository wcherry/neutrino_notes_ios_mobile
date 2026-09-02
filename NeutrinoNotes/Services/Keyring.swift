import Foundation
import CryptoKit

// MARK: - Keyring
//
// Every Curve25519 identity keypair this account has held, numbered.
//
// A single identity cannot be rotated: the moment it changes, every DEK on the
// server is sealed to a key nobody holds any more, and nothing on the key ref
// says which key it wanted. So the identity is a list, and
// `file_key_refs.key_version` names the entry a given DEK needs.
//
//   read   resolve the file's keyVersion against this keyring, open with that
//          entry's secret key
//   write  seal to the *active* entry and record its version
//
// Content is never re-encrypted by a rotation — only the sealed DEK moves.
//
// The wire format is shared with the web client, byte for byte: see
// `web/packages/e2e-crypto/src/keyring.ts`. Two properties are load-bearing and
// silently break cross-device transfer if they drift:
//
//   * entries carry the secret key only. The public half is *derived* on read,
//     so a damaged payload cannot produce a pair whose halves disagree and
//     whose seals are quietly unopenable.
//   * `retiredAt` is null on exactly one entry. Deserialisation rejects
//     anything else rather than guessing which key is current.
//
// Nothing here is ever transmitted to the server. See
// `agent_docs/client-only-key-architecture.md` in the backend repo.

struct KeyringEntry {
    /// 1-based, matching `user_public_keys.version` on the server.
    let version: Int
    let publicKey: [UInt8]
    let secretKey: [UInt8]
    let createdAt: String
    /// nil while this is the active entry.
    let retiredAt: String?

    var isActive: Bool { retiredAt == nil }
}

struct Keyring {
    let userId: String
    /// Ascending by version. Exactly one entry has `retiredAt == nil`.
    let entries: [KeyringEntry]

    /// The entry new work is sealed to.
    var active: KeyringEntry? {
        entries.first(where: { $0.isActive })
    }

    /// The entry a file's DEK was sealed to, or nil if this device lacks it.
    func entry(forVersion version: Int) -> KeyringEntry? {
        entries.first(where: { $0.version == version })
    }
}

// MARK: - Errors

enum KeyringError: LocalizedError {
    case unrecognisedFormat
    case empty
    case badSecretKeyLength(version: Int)
    case duplicateVersions
    case notExactlyOneActive(count: Int)
    case wrongAccount
    case noKeyring
    case missingVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unrecognisedFormat:
            return "This is not a Neutrino key."
        case .empty:
            return "That key is empty."
        case .badSecretKeyLength(let version):
            return "Key version \(version) is damaged."
        case .duplicateVersions:
            return "That key has duplicate versions and cannot be used."
        case .notExactlyOneActive(let count):
            return count == 0
                ? "That key names no current version."
                : "That key names \(count) current versions; it should name exactly one."
        case .wrongAccount:
            return "That key belongs to a different account."
        case .noKeyring:
            return "This device has no encryption key. Restore your recovery kit or pair with a "
                 + "device that has it."
        case .missingVersion(let version):
            return "This file needs encryption key version \(version), which this device does not "
                 + "have. Restore your recovery kit or pair with a device that has it."
        }
    }
}

// MARK: - Wire format

/// What the recovery kit and the pairing QR carry. Field names are fixed by the
/// web implementation; do not rename them.
struct SerializedKeyring: Codable {
    struct Entry: Codable {
        let version: Int
        /// base64url secret key. No public half — it is derived on read.
        let sk: String
        let createdAt: String
        let retiredAt: String?
    }
    let v: Int
    let userId: String
    let entries: [Entry]
}

// MARK: - Coding

enum KeyringCoder {

    static let secretKeyBytes = 32
    private static let formatVersion = 1

    /// Derive the Curve25519 public key from a secret key.
    ///
    /// swift-sodium exposes no `scalarmult_base` wrapper and the app depends on
    /// the `Sodium` product only, not `Clibsodium`. CryptoKit's X25519 performs
    /// the same multiplication.
    static func publicKey(fromSecret secretKey: [UInt8]) -> [UInt8]? {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(secretKey))
        else { return nil }
        return [UInt8](priv.publicKey.rawRepresentation)
    }

    static func serialize(_ keyring: Keyring) -> SerializedKeyring {
        SerializedKeyring(
            v: formatVersion,
            userId: keyring.userId,
            entries: keyring.entries.map {
                SerializedKeyring.Entry(
                    version: $0.version,
                    sk: Base64URL.encode($0.secretKey),
                    createdAt: $0.createdAt,
                    retiredAt: $0.retiredAt
                )
            }
        )
    }

    /// Rebuild a keyring, validating as it goes.
    ///
    /// Everything this parses arrived off paper, a QR code or disk, so none of it
    /// is trusted: a wrong secret-key length, a duplicate version or a keyring
    /// with no current entry are rejected here rather than surfacing later as
    /// files that mysteriously will not open.
    static func deserialize(_ payload: SerializedKeyring) throws -> Keyring {
        guard payload.v == formatVersion else { throw KeyringError.unrecognisedFormat }
        guard !payload.entries.isEmpty else { throw KeyringError.empty }

        var entries: [KeyringEntry] = []
        for entry in payload.entries {
            guard let secretKey = Base64URL.decode(entry.sk),
                  secretKey.count == secretKeyBytes,
                  let publicKey = publicKey(fromSecret: secretKey)
            else {
                throw KeyringError.badSecretKeyLength(version: entry.version)
            }
            entries.append(KeyringEntry(
                version: entry.version,
                publicKey: publicKey,
                secretKey: secretKey,
                createdAt: entry.createdAt,
                retiredAt: entry.retiredAt
            ))
        }

        entries.sort { $0.version < $1.version }

        guard Set(entries.map(\.version)).count == entries.count else {
            throw KeyringError.duplicateVersions
        }
        let activeCount = entries.filter(\.isActive).count
        guard activeCount == 1 else {
            throw KeyringError.notExactlyOneActive(count: activeCount)
        }

        return Keyring(userId: payload.userId, entries: entries)
    }

    /// JSON, as carried by the pairing QR. A plain coder on purpose — the app's
    /// shared snake-case-converting one would rewrite `userId` and `createdAt`.
    static func encodeJSON(_ keyring: Keyring) throws -> Data {
        try JSONEncoder().encode(serialize(keyring))
    }

    static func decodeJSON(_ data: Data) throws -> Keyring {
        let payload: SerializedKeyring
        do {
            payload = try JSONDecoder().decode(SerializedKeyring.self, from: data)
        } catch {
            throw KeyringError.unrecognisedFormat
        }
        return try deserialize(payload)
    }

    /// Adopt a bare keypair as a single-entry keyring.
    ///
    /// For the web app's mobile key code and for key files exported by a build
    /// that predates versioning. Minting a fresh identity instead would orphan
    /// everything already sealed to this one.
    ///
    /// `version` is the keyring version the key actually is, which the key code
    /// carries as `key_version` — **not** always 1. Pinning it to 1 would file
    /// a rotated account's v3 key under v1, and then every note written since
    /// the rotation would fail to open with "this file needs key version 3",
    /// while the key that opens it sat right there under the wrong number. The
    /// caller defaults to 1 only when nothing said otherwise.
    ///
    /// Retired versions do not arrive this way at all: they come from the
    /// account's key file, which `KeyFileService` merges in afterwards.
    static func fromKeyPair(userId: String,
                            publicKey: [UInt8],
                            secretKey: [UInt8],
                            version: Int = 1) -> Keyring {
        Keyring(userId: userId, entries: [
            KeyringEntry(
                version: max(1, version),
                publicKey: publicKey,
                secretKey: secretKey,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                retiredAt: nil
            )
        ])
    }
}

// MARK: - Base64URL

enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url and standard base64, padded or not — the server writes
    /// base64url, but exported key bundles use standard base64.
    static func decode(_ s: String) -> [UInt8]? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = t.count % 4
        if remainder > 0 {
            t += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: t) else { return nil }
        return [UInt8](data)
    }
}
