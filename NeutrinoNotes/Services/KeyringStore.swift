import Foundation
import os
import NeutrinoCore

// MARK: - KeyringStore
//
// This device's copy of the identity keyring, in the Keychain.
//
// Replaces `KeyVaultService`, which fetched a wrapped identity from the server
// and opened it with a password. There is no server copy any more — the key is
// created on a client and never transmitted — so the only ways a keyring
// arrives here are the recovery kit and the pairing handshake, and this is
// where it lands afterwards.
//
// One Keychain item holds the whole serialised keyring. The pre-keyring build
// used three separate items (`nn.encryption.public_key`, `.private_key`,
// `.key_version`); those are purged on first run, see `purgeLegacyItems`.
//
// Protection is the Keychain's own: `WhenUnlockedThisDeviceOnly` (set by
// `KeychainService`), so the keyring is readable while the phone is unlocked and
// is excluded from backups. The app's separate passcode/biometric gate is
// `AppLockService`; it guards the UI, not this.

@MainActor
final class KeyringStore {

    static let shared = KeyringStore()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "KeyringStore")

    /// The serialised keyring. One item, not one per key version.
    static let keyringKeychainKey = "nn.encryption.keyring"

    /// Written by the build that predates versioning. Purged, never migrated:
    /// the keys they hold open files that no longer exist after the server-side
    /// wipe, and a stale private key surviving into the new scheme is worse than
    /// an empty Keychain, which at least routes the user through enrolment.
    private static let legacyKeys = [
        "nn.encryption.public_key",
        "nn.encryption.private_key",
        "nn.encryption.key_version"
    ]

    private static let purgeFlagKey = "nn.encryption.legacyPurged.v1"

    /// Cached so the common read path — every note decrypt — does not hit the
    /// Keychain and re-derive public keys each time.
    private var cached: Keyring?

    private init() {}

    // MARK: - Legacy purge

    /// Remove the pre-keyring Keychain items. Idempotent; runs once per install.
    func purgeLegacyItems() {
        guard !UserDefaults.standard.bool(forKey: Self.purgeFlagKey) else { return }
        for key in Self.legacyKeys {
            KeychainService.delete(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.purgeFlagKey)
        logger.info("purgeLegacyItems: removed pre-keyring Keychain entries")
    }

    // MARK: - Reading

    /// The stored keyring, or nil when this device holds none.
    func load() -> Keyring? {
        if let cached { return cached }
        guard let json = KeychainService.load(forKey: Self.keyringKeychainKey),
              let data = json.data(using: .utf8)
        else { return nil }
        do {
            let keyring = try KeyringCoder.decodeJSON(data)
            cached = keyring
            return keyring
        } catch {
            // A keyring that will not parse is not recoverable by retrying, and
            // treating it as absent is what routes the user to restore it.
            logger.error("load: stored keyring is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var hasKeyring: Bool { load() != nil }

    /// The keypair new work is sealed to.
    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        guard let entry = load()?.active else { return nil }
        return (entry.publicKey, entry.secretKey, entry.version)
    }

    /// The keypair that opens a DEK sealed to `version`.
    ///
    /// Throws rather than returning nil so the caller reports which key is
    /// missing — "this file needs version 2" is actionable, an unexplained
    /// decrypt failure is not.
    func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard let keyring = load() else { throw KeyringError.noKeyring }
        guard let entry = keyring.entry(forVersion: version) else {
            throw KeyringError.missingVersion(version)
        }
        return (entry.publicKey, entry.secretKey)
    }

    // MARK: - Writing

    /// Store `keyring`, replacing whatever this device held.
    @discardableResult
    func store(_ keyring: Keyring) -> Bool {
        do {
            let data = try KeyringCoder.encodeJSON(keyring)
            guard let json = String(data: data, encoding: .utf8) else { return false }
            let ok = KeychainService.save(json, forKey: Self.keyringKeychainKey)
            if ok { cached = keyring }
            logger.info("store: keyring saved, versions=\(keyring.entries.count, privacy: .public)")
            return ok
        } catch {
            logger.error("store: encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Forget this device's copy.
    ///
    /// The keyring survives only where else it is held — another paired device,
    /// or the printed recovery kit. There is no server copy to fall back on.
    func clear() {
        KeychainService.delete(forKey: Self.keyringKeychainKey)
        cached = nil
        logger.info("clear: keyring removed from this device")
    }
}
