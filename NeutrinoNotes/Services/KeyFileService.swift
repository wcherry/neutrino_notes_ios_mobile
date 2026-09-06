import Foundation
import Sodium
import os
import NeutrinoCore
import NeutrinoAuth

// MARK: - KeyFileService
//
// The account's **retired** identity keys, fetched from the server and merged
// into this device's keyring.
//
// A phone enrols by scanning the web app's key code (`KeyQRDecryptService`), and
// that code carries exactly one keypair: the active one. So a phone joining an
// account that has rotated could read everything written since the last rotation
// and nothing written before it — the notes were still there, and still would
// not open. This closes that gap.
//
// ── What the server holds, and why it can hold it ────────────────────────────
// Each retired secret key is sealed with `crypto_box_seal` to the keyring's
// **active** public key before it is uploaded. So the holder of the current
// identity can recover every identity that came before it, and nobody else can —
// the server included, since it has no secret half of anything. Nothing about
// D1 ("no key material is transmitted to the server") is bent here: what is
// transmitted is ciphertext under a key the server does not have.
//
// The active key is deliberately *not* in the file. It is worth nothing without
// one, which is why losing every device and the recovery kit is still terminal;
// see `agent_docs/client-only-key-architecture.md` in the backend repo.
//
// The web side is `web/packages/e2e-crypto/src/keyFile.ts` (`buildKeyFile` /
// `openKeyFile`) and the endpoint is `src/drive/key_files/api.rs`.
//
// ── What the file does not carry ─────────────────────────────────────────────
// No per-key `createdAt`/`retiredAt`. The file exists so a version can still be
// *decrypted*, and timestamps do not serve that. The keyring model needs both
// fields, so they are taken from the document's own timestamps — see
// `entry(from:createdAt:retiredAt:)`. The one property that matters is that a
// recovered entry is retired, so exactly one entry stays active.

// MARK: - Wire types
//
// camelCase on the wire. Decode with a plain JSONDecoder — the app's shared
// snake-case-converting one would rewrite `keyVersion` and the parse would fail.

struct ArchivedKeyDTO: Codable {
    /// The `user_public_keys.version` this entry unwraps to.
    let keyVersion: Int
    /// base64url sealed box over the retired secret key.
    let encryptedKey: String
    /// base64url public half, so an entry can be matched before it is unsealed.
    let publicKey: String?
}

struct KeyFileResponseDTO: Codable {
    let userId: String
    /// Ascending by `keyVersion`.
    let keys: [ArchivedKeyDTO]
    let createdAt: String
    let updatedAt: String
}

// MARK: - Outcome

/// What a pull actually did. Reported rather than swallowed: "your older notes
/// still will not open" is something the user has to be told, and the difference
/// between "there was nothing to fetch" and "there was, and none of it opened"
/// is the difference between a healthy account and a wrong key.
struct KeyFileRestoreOutcome: Equatable {
    /// Versions added to this device's keyring by this pull.
    var recovered: Int = 0
    /// Versions the file carried that this device already had.
    var alreadyHeld: Int = 0
    /// Versions the file carried that would not open. With the account's real
    /// active key this is zero, so a non-zero count means the entry is damaged
    /// or was sealed to something other than what this device holds.
    var unopenable: Int = 0

    /// True when this device's *active* key turns up in the file.
    ///
    /// The file holds retired keys only, so a version appearing in it that this
    /// device believes is current means the account has rotated since this key
    /// was issued — and the newest version is not in the file either, because
    /// only the retired ones are. That device cannot read anything written
    /// since the rotation and cannot fix it from here; it needs a fresh key.
    ///
    /// This is the one reliable staleness signal available from the file alone,
    /// which is why it is computed here rather than by comparing against the
    /// published public keys in a second round trip.
    var activeIsStale: Bool = false

    /// True when the server answered 404: this account has no key file at all.
    ///
    /// Distinct from an empty result, and the distinction is the whole point.
    /// For an account that has never rotated it is unremarkable. For one whose
    /// active version is 2 or higher it means the retired keys were never backed
    /// up from the device that rotated — so they exist in exactly one browser
    /// profile, no phone can ever open the notes sealed to them, and no amount
    /// of re-scanning here will change that. Only that browser can fix it.
    var serverHasNoKeyFile: Bool = false

    /// True when nothing was recovered, held, or refused.
    var isEmpty: Bool { recovered == 0 && alreadyHeld == 0 && unopenable == 0 }
}

// MARK: - Errors

enum KeyFileError: LocalizedError {
    case notAuthenticated
    case noKeyring
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case couldNotStore

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are signed out. Sign in and try again."
        case .noKeyring:
            return "This device has no encryption key yet, so there is nothing to unlock your "
                 + "older keys with."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .decodingError:
            return "The server sent a key file this version of the app does not understand."
        case .couldNotStore:
            return "Could not save the recovered keys to this device."
        }
    }
}

// MARK: - KeyFileService

@MainActor
final class KeyFileService {

    static let shared = KeyFileService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "KeyFileService")

    private static let sodium = Sodium()
    private static let decoder = JSONDecoder()

    weak var authService: AuthService?

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    private init() {}

    // MARK: - Restore

    /// Fetch the account's key file and merge whatever it yields into this
    /// device's keyring.
    ///
    /// Call this after a key arrives from anywhere — the key code, the recovery
    /// kit, a paired device — because in every one of those cases the device has
    /// just acquired the active key, which is the only thing that opens the file.
    @discardableResult
    func restoreArchivedKeys(using authService: AuthService) async throws -> KeyFileRestoreOutcome {
        self.authService = authService

        guard let keyring = KeyringStore.shared.load(), let active = keyring.active else {
            throw KeyFileError.noKeyring
        }
        guard let response = try await fetch(authService: authService) else {
            logger.info("restoreArchivedKeys: no key file stored for this account")
            return KeyFileRestoreOutcome(serverHasNoKeyFile: true)
        }

        let plan = Self.plan(response: response, keyring: keyring, active: active)
        let outcome = plan.outcome

        if outcome.unopenable > 0 {
            logger.error("restoreArchivedKeys: \(outcome.unopenable, privacy: .public) entr(ies) did not open with active version \(active.version, privacy: .public)")
        }

        if !plan.entries.isEmpty {
            let merged = Keyring(userId: keyring.userId,
                                 entries: (keyring.entries + plan.entries).sorted { $0.version < $1.version })
            guard KeyringStore.shared.store(merged) else { throw KeyFileError.couldNotStore }
        }

        logger.info("restoreArchivedKeys: recovered=\(outcome.recovered, privacy: .public) held=\(outcome.alreadyHeld, privacy: .public) unopenable=\(outcome.unopenable, privacy: .public)")
        return outcome
    }

    // MARK: - Unsealing

    /// What a fetched key file yields against a keyring.
    ///
    /// The pure half of `restoreArchivedKeys`, split out so the decisions that
    /// matter — which entries open, which are already held, whether the active
    /// key is stale — can be tested against real ciphertext with no network in
    /// the way.
    static func plan(response: KeyFileResponseDTO,
                     keyring: Keyring,
                     active: KeyringEntry)
    -> (outcome: KeyFileRestoreOutcome, entries: [KeyringEntry]) {
        var outcome = KeyFileRestoreOutcome()
        var recovered: [KeyringEntry] = []

        // Retired keys are the only thing in the file, so our "active" appearing
        // in it means it is not active any more. See `activeIsStale`.
        outcome.activeIsStale = response.keys.contains { $0.keyVersion >= active.version }

        for key in response.keys {
            if keyring.entry(forVersion: key.keyVersion) != nil {
                outcome.alreadyHeld += 1
                continue
            }
            guard let entry = entry(from: key,
                                    active: active,
                                    createdAt: response.createdAt,
                                    retiredAt: response.updatedAt) else {
                // Almost always an entry sealed to a version newer than the one
                // in hand, which reads as a decryption failure but really means
                // "this device's key is not the newest one".
                outcome.unopenable += 1
                continue
            }
            recovered.append(entry)
            outcome.recovered += 1
        }
        return (outcome, recovered)
    }

    /// Open one archived key with the active keypair.
    ///
    /// Everything here came off the network, so none of it is trusted: a secret
    /// key of the wrong length, or a declared public half that is not the
    /// secret's own, is rejected rather than installed. Either would surface
    /// later as notes that mysteriously will not open, which is a far worse
    /// failure than refusing the entry now. This mirrors `deserialize` in
    /// `Keyring.swift`, which guards the kit and pairing paths for the same
    /// reason.
    static func entry(from key: ArchivedKeyDTO,
                      active: KeyringEntry,
                      createdAt: String,
                      retiredAt: String) -> KeyringEntry? {
        guard let sealed = Base64URL.decode(key.encryptedKey) else { return nil }
        guard let secretKey = sodium.box.open(anonymousCipherText: sealed,
                                              recipientPublicKey: active.publicKey,
                                              recipientSecretKey: active.secretKey),
              secretKey.count == KeyringCoder.secretKeyBytes,
              let publicKey = KeyringCoder.publicKey(fromSecret: secretKey)
        else { return nil }

        if let declared = key.publicKey, Base64URL.encode(publicKey) != declared {
            return nil
        }

        return KeyringEntry(version: key.keyVersion,
                            publicKey: publicKey,
                            secretKey: secretKey,
                            createdAt: createdAt,
                            retiredAt: retiredAt)
    }

    // MARK: - HTTP

    /// The caller's key file, or nil when they have never stored one.
    ///
    /// A 404 is a state and not a failure: an account that has never rotated has
    /// no retired keys to archive, and the server rejects an empty key file
    /// rather than storing one.
    private func fetch(authService: AuthService) async throws -> KeyFileResponseDTO? {
        await authService.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw KeyFileError.notAuthenticated
        }
        guard let url = URL(string: baseURL + "/api/v1/drive/key-file") else {
            throw KeyFileError.serverError(statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyFileError.serverError(statusCode: 0)
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyFileError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(KeyFileResponseDTO.self, from: data)
        } catch {
            logger.error("fetch: decode failed: \(error.localizedDescription, privacy: .public)")
            throw KeyFileError.decodingError(underlying: error)
        }
    }
}
