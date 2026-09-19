import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoNotes

// MARK: - KeyringTests
//
// The keyring, the recovery kit and the pairing handshake.
//
// The wire formats here are shared with the web client byte for byte, so several
// of these tests assert on the *encoding* rather than just on round-tripping —
// a change that still round-trips locally but drifts from `keyring.ts` would
// silently break restoring a kit printed on the web.

final class KeyringTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Model

    func test_entryForVersion_findsRetiredVersions() throws {
        let keyring = try makeKeyring(versions: 3)

        XCTAssertEqual(keyring.entry(forVersion: 1)?.version, 1)
        XCTAssertEqual(keyring.active?.version, 3)
        XCTAssertNil(keyring.entry(forVersion: 9))
    }

    // MARK: - Serialisation

    func test_serializeThenDeserialize_preservesEveryVersion() throws {
        let keyring = try makeKeyring(versions: 3)

        let restored = try KeyringCoder.deserialize(KeyringCoder.serialize(keyring))

        XCTAssertEqual(restored.entries.map(\.version), [1, 2, 3])
        XCTAssertEqual(restored.entries.map(\.secretKey), keyring.entries.map(\.secretKey))
        XCTAssertEqual(restored.active?.version, 3)
    }

    /// The serialised form carries secret keys only; public halves are derived.
    /// A stored public key could disagree with its secret and produce seals that
    /// silently never open.
    func test_serializedForm_carriesNoPublicKey() throws {
        let keyring = try makeKeyring(versions: 1)

        let json = String(data: try KeyringCoder.encodeJSON(keyring), encoding: .utf8)!

        XCTAssertFalse(json.contains("\"pk\""))
        let restored = try KeyringCoder.decodeJSON(Data(json.utf8))
        XCTAssertEqual(restored.entries[0].publicKey, keyring.entries[0].publicKey)
    }

    func test_deserialize_rejectsAKeyringWithNoActiveEntry() throws {
        var payload = KeyringCoder.serialize(try makeKeyring(versions: 1))
        payload = SerializedKeyring(v: 1, userId: payload.userId, entries: [
            .init(version: 1, sk: payload.entries[0].sk,
                  createdAt: payload.entries[0].createdAt, retiredAt: "2026-01-01T00:00:00Z")
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            guard case KeyringError.notExactlyOneActive(let count) = error else {
                return XCTFail("Expected notExactlyOneActive, got \(error)")
            }
            XCTAssertEqual(count, 0)
        }
    }

    func test_deserialize_rejectsTwoActiveEntries() throws {
        let source = KeyringCoder.serialize(try makeKeyring(versions: 2))
        let payload = SerializedKeyring(v: 1, userId: source.userId, entries: source.entries.map {
            .init(version: $0.version, sk: $0.sk, createdAt: $0.createdAt, retiredAt: nil)
        })

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            guard case KeyringError.notExactlyOneActive = error else {
                return XCTFail("Expected notExactlyOneActive, got \(error)")
            }
        }
    }

    func test_deserialize_rejectsASecretKeyOfTheWrongLength() throws {
        let source = KeyringCoder.serialize(try makeKeyring(versions: 1))
        let payload = SerializedKeyring(v: 1, userId: source.userId, entries: [
            .init(version: 1, sk: "AAAA", createdAt: source.entries[0].createdAt, retiredAt: nil)
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload))
    }

    // MARK: - Recovery kit

    func test_recoveryKit_roundTripsEveryVersion() throws {
        let keyring = try makeKeyring(versions: 3)

        let restored = try RecoveryKit.importKit(RecoveryKit.export(keyring),
                                                 userId: keyring.userId)

        XCTAssertEqual(restored.entries.map(\.version), [1, 2, 3])
        XCTAssertEqual(restored.entries.map(\.secretKey), keyring.entries.map(\.secretKey))
        XCTAssertEqual(restored.active?.version, 3)
    }

    /// Crockford's alphabet exists so these substitutions are recoverable —
    /// someone copying off paper writes O for 0 and l for 1 whatever the
    /// alphabet says.
    func test_recoveryKit_survivesTheTranscriptionMistakesItsAlphabetAbsorbs() throws {
        let keyring = try makeKeyring(versions: 1)
        let kit = RecoveryKit.export(keyring)

        let mangled = kit.lowercased()
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "l")

        XCTAssertEqual(try RecoveryKit.importKit(mangled, userId: keyring.userId)
                        .entries[0].secretKey,
                       keyring.entries[0].secretKey)
    }

    func test_recoveryKit_ignoresItsOwnGroupingAndWhitespace() throws {
        let keyring = try makeKeyring(versions: 1)
        let kit = RecoveryKit.export(keyring)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\n", with: "  ")

        XCTAssertEqual(try RecoveryKit.importKit(kit, userId: keyring.userId)
                        .entries[0].secretKey,
                       keyring.entries[0].secretKey)
    }

    /// A hand-copied kit is most likely to go wrong by being short. Say so,
    /// rather than letting a truncated read produce a subtly wrong key.
    func test_recoveryKit_reportsATruncatedKitRatherThanAWrongKey() throws {
        let kit = RecoveryKit.export(try makeKeyring(versions: 1))

        XCTAssertThrowsError(try RecoveryKit.importKit(String(kit.prefix(20)),
                                                       userId: "test-user")) { error in
            guard case RecoveryKitError.incomplete = error else {
                return XCTFail("Expected .incomplete, got \(error)")
            }
        }
    }

    func test_recoveryKit_rejectsTextThatIsNotAKit() {
        XCTAssertThrowsError(try RecoveryKit.importKit("hello there", userId: "test-user"))
        XCTAssertFalse(RecoveryKit.looksLikeKit("hello there"))
    }

    func test_looksLikeKit_acceptsARealKit() throws {
        XCTAssertTrue(RecoveryKit.looksLikeKit(RecoveryKit.export(try makeKeyring(versions: 1))))
    }

    // MARK: - Pairing

    func test_pairing_carriesTheWholeKeyringToTheReceiver() throws {
        let source = try makeKeyring(versions: 2)
        let session = Pairing.createSession()
        let response = try makeResponse(for: source, offer: session.offer)

        let received = try Pairing.accept(response, session: session, userId: source.userId)

        XCTAssertEqual(received.entries.map(\.secretKey), source.entries.map(\.secretKey))
    }

    func test_pairing_confirmationCodeIsSixDigitsAndStable() throws {
        let keyring = try makeKeyring(versions: 1)
        let session = Pairing.createSession()
        let response = try makeResponse(for: keyring, offer: session.offer)

        let code = Pairing.confirmationCode(offer: session.offer, response: response)

        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertEqual(code, Pairing.confirmationCode(offer: session.offer, response: response))
    }

    /// The attack the spoken code exists to catch: a relay can complete both
    /// halves of the exchange, but it cannot make the two transcripts agree.
    func test_pairing_aRelayProducesADifferentConfirmationCode() throws {
        let keyring = try makeKeyring(versions: 1)

        let honest = Pairing.createSession()
        let honestResponse = try makeResponse(for: keyring, offer: honest.offer)

        let relay = Pairing.createSession()
        let relayResponse = try makeResponse(for: keyring, offer: relay.offer)

        XCTAssertNotEqual(
            Pairing.confirmationCode(offer: honest.offer, response: honestResponse),
            Pairing.confirmationCode(offer: relay.offer, response: relayResponse)
        )
    }

    func test_pairing_refusesAResponseFromADifferentAttempt() throws {
        let keyring = try makeKeyring(versions: 1)
        let first = Pairing.createSession()
        let second = Pairing.createSession()
        let responseToSecond = try makeResponse(for: keyring, offer: second.offer)

        XCTAssertThrowsError(
            try Pairing.accept(responseToSecond, session: first, userId: keyring.userId)
        ) { error in
            guard case PairingError.differentAttempt = error else {
                return XCTFail("Expected .differentAttempt, got \(error)")
            }
        }
    }

    func test_pairing_refusesAKeyringForAnotherAccount() throws {
        let keyring = try makeKeyring(versions: 1)
        let session = Pairing.createSession()
        let response = try makeResponse(for: keyring, offer: session.offer)

        XCTAssertThrowsError(
            try Pairing.accept(response, session: session, userId: "somebody-else")
        ) { error in
            guard case KeyringError.wrongAccount = error else {
                return XCTFail("Expected .wrongAccount, got \(error)")
            }
        }
    }

    /// Photographing QR-A gains nothing: it is a public key, and only the
    /// receiver holds the secret half that opens QR-B.
    func test_pairing_anEavesdropperCannotOpenTheResponse() throws {
        let keyring = try makeKeyring(versions: 1)
        let real = Pairing.createSession()
        let response = try makeResponse(for: keyring, offer: real.offer)

        let eavesdropper = Pairing.createSession()
        // Same nonce so the attempt check passes and the *crypto* is what fails.
        let forged = PairingResponse(t: response.t, v: 1, ct: response.ct,
                                     n: eavesdropper.offer.n)

        XCTAssertThrowsError(
            try Pairing.accept(forged, session: eavesdropper, userId: keyring.userId)
        )
    }

    func test_pairing_rejectsPayloadsThatAreNotPairingCodes() {
        XCTAssertThrowsError(try Pairing.parseResponse("not json"))
        XCTAssertThrowsError(try Pairing.parseResponse(#"{"t":"something-else","v":1}"#))
    }

    // MARK: - Helpers

    private func makeKeyring(versions: Int, userId: String = "test-user") throws -> Keyring {
        var entries: [KeyringEntry] = []
        for version in 1...versions {
            let keyPair = sodium.box.keyPair()!
            entries.append(KeyringEntry(
                version: version,
                publicKey: keyPair.publicKey,
                secretKey: keyPair.secretKey,
                createdAt: "2026-08-20T00:00:00Z",
                retiredAt: version == versions ? nil : "2026-08-21T00:00:00Z"
            ))
        }
        return Keyring(userId: userId, entries: entries)
    }

    /// Stands in for the web client: seals the keyring to the offer's ephemeral
    /// public key, exactly as `respondToPairingOffer` does there.
    private func makeResponse(for keyring: Keyring, offer: PairingOffer) throws -> PairingResponse {
        let plaintext = try KeyringCoder.encodeJSON(keyring)
        let recipient = Base64URL.decode(offer.pk)!
        let sealed = sodium.box.seal(message: [UInt8](plaintext), recipientPublicKey: recipient)!
        return PairingResponse(t: PairingResponse.type, v: 1,
                               ct: Base64URL.encode(sealed), n: offer.n)
    }
}
