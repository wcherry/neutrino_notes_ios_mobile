import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoNotes

// MARK: - KeyFileServiceTests
//
// The key file is what lets a phone read notes written before the account's last
// rotation. It arrives as ciphertext the server cannot open, so the only place
// the entries are checked is here — which makes "what does this accept, and what
// does it refuse" the whole of the security story for this path.
//
// `plan` is tested rather than `restoreArchivedKeys`, because everything the
// latter adds is one authenticated GET; the decisions are all in `plan`, and
// they are exercised here against real sealed boxes rather than fixtures.

@MainActor
final class KeyFileServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Fixtures

    /// A key file as the web app's `buildKeyFile` would have written it: every retired secret key
    /// sealed to the active public key.
    private func keyFile(archiving retired: [(version: Int, pair: Box.KeyPair)],
                         sealedTo active: Box.KeyPair,
                         declarePublicKey: Bool = true) -> KeyFileResponseDTO {
        KeyFileResponseDTO(
            userId: KeyringTestSupport.testUserID,
            keys: retired.map { entry in
                ArchivedKeyDTO(
                    keyVersion: entry.version,
                    encryptedKey: Base64URL.encode(
                        sodium.box.seal(message: entry.pair.secretKey,
                                        recipientPublicKey: active.publicKey)!),
                    publicKey: declarePublicKey ? Base64URL.encode(entry.pair.publicKey) : nil
                )
            },
            createdAt: "2026-08-01T00:00:00Z",
            updatedAt: "2026-08-22T00:00:00Z"
        )
    }

    private func keyring(_ pairs: [(version: Int, pair: Box.KeyPair)],
                         activeVersion: Int) -> Keyring {
        Keyring(userId: KeyringTestSupport.testUserID, entries: pairs.map { entry in
            KeyringEntry(version: entry.version,
                         publicKey: entry.pair.publicKey,
                         secretKey: entry.pair.secretKey,
                         createdAt: "2026-08-20T00:00:00Z",
                         retiredAt: entry.version == activeVersion ? nil : "2026-08-21T00:00:00Z")
        })
    }

    // MARK: - The case this exists for

    /// A phone that scanned the key code holds v3 and nothing else. Everything written before the
    /// last rotation is sealed to v1 and v2, and this is the only thing that brings them across.
    func testRecoversTheRetiredKeysAPhoneNeverReceived() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        let onlyActive = keyring([(3, v3)], activeVersion: 3)
        let file = keyFile(archiving: [(1, v1), (2, v2)], sealedTo: v3)

        let plan = KeyFileService.plan(response: file,
                                       keyring: onlyActive,
                                       active: onlyActive.active!)

        XCTAssertEqual(plan.outcome.recovered, 2)
        XCTAssertEqual(plan.outcome.alreadyHeld, 0)
        XCTAssertEqual(plan.outcome.unopenable, 0)
        XCTAssertFalse(plan.outcome.activeIsStale)

        XCTAssertEqual(plan.entries.map(\.version), [1, 2])
        XCTAssertEqual(plan.entries[0].secretKey, v1.secretKey)
        XCTAssertEqual(plan.entries[1].secretKey, v2.secretKey)
    }

    /// Every recovered entry has to be retired, or the merged keyring names two current versions
    /// and `deserialize` refuses to load it on the next launch.
    func testRecoveredKeysAreRetired() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let onlyActive = keyring([(2, v2)], activeVersion: 2)

        let plan = KeyFileService.plan(response: keyFile(archiving: [(1, v1)], sealedTo: v2),
                                       keyring: onlyActive,
                                       active: onlyActive.active!)

        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertFalse(plan.entries[0].isActive)

        let merged = Keyring(userId: onlyActive.userId,
                             entries: (onlyActive.entries + plan.entries).sorted { $0.version < $1.version })
        XCTAssertEqual(merged.entries.filter(\.isActive).count, 1)
        // The merged keyring must survive a round trip through storage, since that is what the
        // next launch reads.
        XCTAssertNoThrow(try KeyringCoder.deserialize(KeyringCoder.serialize(merged)))
    }

    // MARK: - Repeat pulls

    /// The launch-time top-up runs on every start. A device that already has everything must come
    /// back with nothing recovered rather than growing a second copy of each version.
    func testAKeyAlreadyHeldIsReportedRatherThanDuplicated() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let complete = keyring([(1, v1), (2, v2)], activeVersion: 2)

        let plan = KeyFileService.plan(response: keyFile(archiving: [(1, v1)], sealedTo: v2),
                                       keyring: complete,
                                       active: complete.active!)

        XCTAssertEqual(plan.outcome.alreadyHeld, 1)
        XCTAssertEqual(plan.outcome.recovered, 0)
        XCTAssertTrue(plan.entries.isEmpty)
    }

    // MARK: - Staleness

    /// A recovery kit printed before a rotation installs a keyring whose "active" entry the server
    /// has since retired. The file lists that version, which is the one signal available here that
    /// the kit is out of date — and the device is missing the newest key entirely.
    func testAnActiveVersionAppearingInTheFileIsReportedAsStale() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        // The device thinks v2 is current; the account has moved on to v3, so the file archives
        // v1 *and* v2, both sealed to v3.
        let staleKit = keyring([(1, v1), (2, v2)], activeVersion: 2)
        let file = keyFile(archiving: [(1, v1), (2, v2)], sealedTo: v3)

        let plan = KeyFileService.plan(response: file,
                                       keyring: staleKit,
                                       active: staleKit.active!)

        XCTAssertTrue(plan.outcome.activeIsStale)
    }

    func testAFileSealedToANewerKeyOpensNothing() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        // Only v2 in hand, and the file was sealed to v3.
        let behind = keyring([(2, v2)], activeVersion: 2)
        let file = keyFile(archiving: [(1, v1)], sealedTo: v3)

        let plan = KeyFileService.plan(response: file, keyring: behind, active: behind.active!)

        XCTAssertEqual(plan.outcome.unopenable, 1)
        XCTAssertEqual(plan.outcome.recovered, 0)
        XCTAssertTrue(plan.entries.isEmpty)
    }

    // MARK: - What is refused

    /// The declared public half is checked against the one derived from the secret, never trusted
    /// in its place. A mismatch means the entry is not what it claims, and installing it would
    /// surface later as notes that will not open.
    func testAnEntryWhoseDeclaredPublicKeyDoesNotMatchIsRefused() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let imposter = sodium.box.keyPair()!

        var file = keyFile(archiving: [(1, v1)], sealedTo: v2)
        file = KeyFileResponseDTO(
            userId: file.userId,
            keys: [ArchivedKeyDTO(keyVersion: 1,
                                  encryptedKey: file.keys[0].encryptedKey,
                                  publicKey: Base64URL.encode(imposter.publicKey))],
            createdAt: file.createdAt,
            updatedAt: file.updatedAt
        )

        let onlyActive = keyring([(2, v2)], activeVersion: 2)
        let plan = KeyFileService.plan(response: file, keyring: onlyActive, active: onlyActive.active!)

        XCTAssertEqual(plan.outcome.unopenable, 1)
        XCTAssertTrue(plan.entries.isEmpty)
    }

    /// A sealed secret of the wrong length is a damaged entry, not a key. It is dropped rather than
    /// stored, since a 16-byte "secret key" clamps into a perfectly valid-looking scalar that opens
    /// nothing.
    func testAnEntryCarryingTheWrongNumberOfBytesIsRefused() throws {
        let v2 = sodium.box.keyPair()!
        let truncated = sodium.box.seal(message: Array(sodium.randomBytes.buf(length: 16)!),
                                        recipientPublicKey: v2.publicKey)!

        let file = KeyFileResponseDTO(
            userId: KeyringTestSupport.testUserID,
            keys: [ArchivedKeyDTO(keyVersion: 1,
                                  encryptedKey: Base64URL.encode(truncated),
                                  publicKey: nil)],
            createdAt: "2026-08-01T00:00:00Z",
            updatedAt: "2026-08-22T00:00:00Z"
        )

        let onlyActive = keyring([(2, v2)], activeVersion: 2)
        let plan = KeyFileService.plan(response: file, keyring: onlyActive, active: onlyActive.active!)

        XCTAssertEqual(plan.outcome.unopenable, 1)
        XCTAssertTrue(plan.entries.isEmpty)
    }

    /// The public half is optional on the wire. Without it the entry is still accepted — the half
    /// is derived from the secret either way — so an older writer's file is not turned away.
    func testAnEntryWithNoDeclaredPublicKeyIsStillAccepted() throws {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let onlyActive = keyring([(2, v2)], activeVersion: 2)

        let plan = KeyFileService.plan(
            response: keyFile(archiving: [(1, v1)], sealedTo: v2, declarePublicKey: false),
            keyring: onlyActive,
            active: onlyActive.active!)

        XCTAssertEqual(plan.outcome.recovered, 1)
        XCTAssertEqual(plan.entries[0].publicKey, v1.publicKey)
    }

    // MARK: - Wire format

    /// The response is decoded with a plain `JSONDecoder`, so the field names have to match the
    /// server's camelCase exactly. A snake-case-converting decoder here would silently fail.
    func testDecodesTheServersResponseShape() throws {
        let json = """
        {"userId":"u1",
         "keys":[{"keyVersion":2,"encryptedKey":"AAAA","publicKey":"BBBB"}],
         "createdAt":"2026-08-01T00:00:00Z",
         "updatedAt":"2026-08-22T00:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(KeyFileResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.userId, "u1")
        XCTAssertEqual(decoded.keys.count, 1)
        XCTAssertEqual(decoded.keys[0].keyVersion, 2)
        XCTAssertEqual(decoded.keys[0].encryptedKey, "AAAA")
        XCTAssertEqual(decoded.keys[0].publicKey, "BBBB")
    }
}
