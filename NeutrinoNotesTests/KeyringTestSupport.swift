import Foundation
import Sodium
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

    @MainActor
    static func clear() {
        KeyringStore.shared.clear()
    }
}
