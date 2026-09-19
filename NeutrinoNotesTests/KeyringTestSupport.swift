import Foundation
import Sodium
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoNotes

// MARK: - KeyringTestSupport
//
// Installing key material for tests.
//
// Before the keyring, a test set three loose Keychain entries (public key,
// private key, version). There is now one entry holding a serialised keyring, so
// every such test goes through here instead — which also means a test can set up
// a *rotated* account, which was not expressible before.

enum KeyringTestSupport {

    static let testUserID = "test-user"

    /// Install a single-version keyring and return its keypair.
    @discardableResult
    @MainActor
    static func installKeyring(userId: String = testUserID) -> Box.KeyPair {
        let sodium = Sodium()
        let keyPair = sodium.box.keyPair()!
        let keyring = Keyring(userId: userId, entries: [
            KeyringEntry(version: 1,
                         publicKey: keyPair.publicKey,
                         secretKey: keyPair.secretKey,
                         createdAt: "2026-08-20T00:00:00Z",
                         retiredAt: nil)
        ])
        KeyringStore.shared.store(keyring)
        return keyPair
    }

    /// Install a keyring with `versions` entries, the last of them active.
    ///
    /// Returns them in version order, so a test can seal to an *old* key and
    /// check it still opens after the rotation.
    @discardableResult
    @MainActor
    static func installRotatedKeyring(
        versions: Int,
        userId: String = testUserID
    ) -> [Box.KeyPair] {
        let sodium = Sodium()
        var pairs: [Box.KeyPair] = []
        var entries: [KeyringEntry] = []
        for version in 1...versions {
            let keyPair = sodium.box.keyPair()!
            pairs.append(keyPair)
            entries.append(KeyringEntry(
                version: version,
                publicKey: keyPair.publicKey,
                secretKey: keyPair.secretKey,
                createdAt: "2026-08-20T00:00:00Z",
                retiredAt: version == versions ? nil : "2026-08-21T00:00:00Z"
            ))
        }
        KeyringStore.shared.store(Keyring(userId: userId, entries: entries))
        return pairs
    }

    /// Install a keyring in the *private*, per-app Keychain item, bypassing `KeyringStore.store`.
    ///
    /// The shape an app carried before the keyring moved to the cross-app group: one item under
    /// `nn.encryption.keyring`, not keyed by account. It is the only way `.belongsToAnotherAccount`
    /// can still arise — the shared item is keyed by user id, so a second account signing in on
    /// this device looks the item up under *its own* id and simply does not find one.
    @MainActor
    static func installLegacyPrivateKeyring(userId: String) {
        let sodium = Sodium()
        let keyPair = sodium.box.keyPair()!
        let keyring = Keyring(userId: userId, entries: [
            KeyringEntry(version: 1,
                         publicKey: keyPair.publicKey,
                         secretKey: keyPair.secretKey,
                         createdAt: "2026-08-20T00:00:00Z",
                         retiredAt: nil)
        ])
        let json = String(data: try! KeyringCoder.encodeJSON(keyring), encoding: .utf8)!
        KeychainService.save(json, forKey: KeyringStore.keyringKeychainKey)
        KeyringStore.shared.bind(userID: nil)   // drop any cached read
    }

    /// Remove key material from **both** namespaces.
    ///
    /// `KeyringStore.clear()` deliberately leaves the shared item alone — signing out of Notes must
    /// not take Drive's identity with it — so a test that used only that would leak a keyring into
    /// the simulator's cross-app group and into the next test case, which would then find a key
    /// where it set none up.
    @MainActor
    static func clear(userId: String = testUserID) {
        // Bind explicitly rather than relying on the token: these tests mostly run with no session
        // in the Keychain, so an unbound store could not name the shared account to remove and a
        // keyring would survive into the next test case.
        KeyringStore.shared.bind(userID: userId)
        KeyringStore.shared.removeKeyringEverywhere()
    }
}
