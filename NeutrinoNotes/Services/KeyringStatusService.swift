import Foundation
import os
import NeutrinoAuth

// MARK: - KeyringStatus

/// Whether this device can read the signed-in account's notes.
///
/// The counterpart of `VaultStatus` in the apps that still carry a server-side key vault, with one
/// difference that shapes everything here: there is nothing to ask the server. The keyring is
/// created on a client and never transmitted, so "does this device hold the key" is answered
/// entirely by the Keychain — which means this check is free, cannot fail, and has no offline case.
enum KeyringStatus: Equatable {
    /// Not looked yet — the launch state, before the first `refresh()`.
    case unknown
    /// This device holds the signed-in account's keyring.
    case present
    /// No keyring on this device. Notes will not open until one is restored.
    case missing
    /// A keyring is here, but it belongs to a different account — what happens after signing out
    /// and into a second account on the same device. Worth separating from `missing`, because the
    /// symptom is different: every note fails to decrypt rather than the app saying it has no key.
    case belongsToAnotherAccount

    /// The two states that mean "this device cannot read anything", which is what the prompt is
    /// offered for.
    var needsKeyring: Bool { self == .missing || self == .belongsToAnotherAccount }
}

// MARK: - KeyringStatusService

/// Answers "can this device read the account's notes" at sign-in, so the app can ask for the
/// recovery kit then rather than at the first note the user taps.
///
/// Thin on purpose. `KeyringStore` is the store and stays a plain singleton — every note decrypt
/// goes through it and it must not be tied to a view's lifetime. This exists only to make the
/// answer *observable*, which is what lets `RootContentView` present the restore sheet and Settings
/// warn about a keyring from another account.
@MainActor
final class KeyringStatusService: ObservableObject {

    @Published private(set) var status: KeyringStatus = .unknown

    weak var authService: AuthService?

    private let store: KeyringStore

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "KeyringStatusService")

    init(store: KeyringStore = .shared, authService: AuthService? = nil) {
        self.store = store
        self.authService = authService
    }

    // MARK: - Status

    /// Re-reads the Keychain. Called at launch, after sign-in, and after anything that installs or
    /// removes a keyring.
    ///
    /// `async` only because reading the account id decodes the access token; nothing here touches
    /// the network.
    func refresh() async {
        guard let keyring = store.load() else {
            status = .missing
            logger.debug("keyring status: missing")
            return
        }
        // A keyring whose account cannot be determined is treated as this account's rather than
        // another's: a token that will not decode is a session problem, and sending the user to
        // restore a key they already hold would be the wrong instruction.
        guard let userID = await authService?.currentUserID() else {
            status = .present
            return
        }
        status = keyring.userId == userID ? .present : .belongsToAnotherAccount
        logger.debug("keyring status: \(String(describing: self.status), privacy: .public)")
    }

    /// Forgets what it learned. Called on sign-out, so the next account to sign in on this device
    /// is judged against its own keyring rather than the last one's.
    func reset() {
        status = .unknown
    }
}
