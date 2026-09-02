import SwiftUI
import NeutrinoAuth
import NeutrinoUI

// MARK: - KeyRestoreView
//
// Getting the encryption key onto this device.
//
// This replaces `VaultUnlockView`, which fetched a wrapped identity from the
// server and opened it with the account's encryption password. There is no
// server-side copy of the *active* key any more — it is created on a client and
// never transmitted — so there are three ways in:
//
//   key code       scan the PIN-protected QR the web app shows (`KeyQRImportView`)
//   recovery kit   the printed backup, typed in
//   pair a device  the two-QR handshake with a device that already has the key
//
// The key code is listed first because it is the one the web app offers today;
// its sender half is a page in Settings, where pairing's no longer is. The kit
// is the stronger path — it carries every version and never touches the network
// — and stays for exactly that reason.
//
// Two of the three carry the active key only. Both therefore finish by pulling
// the account's key file (`KeyFileService`), which holds the *retired* versions
// sealed to the active public key. Skipping that leaves a device that opens
// everything written since the last rotation and nothing written before it.
//
// There is deliberately no "create a new key" here. This account's files are
// sealed to an identity that already exists; minting a fresh one would orphan
// every one of them, unrecoverably.

struct KeyRestoreView: View {
    @Binding var isPresented: Bool
    var onImported: () -> Void

    @EnvironmentObject private var authService: AuthService

    @State private var kitText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var showPairing = false
    @State private var showKeyCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your key was created on another device and never sent to us, so it "
                         + "cannot be reset. Bring it here from the web app, from your recovery "
                         + "kit, or from a device that still has it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Key code from the web") {
                    Button {
                        showKeyCode = true
                    } label: {
                        Label("Scan key code", systemImage: "qrcode.viewfinder")
                    }
                    Text("On the web, open Settings → Encryption and choose “Key code for "
                         + "mobile”. The code expires after two minutes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Recovery kit") {
                    TextEditor(text: $kitText)
                        .frame(minHeight: 110)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    Button {
                        Task { await restoreFromKit() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Restore key")
                        }
                    }
                    .disabled(isWorking || kitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Another device") {
                    Button {
                        showPairing = true
                    } label: {
                        Label("Pair with a device", systemImage: "qrcode")
                    }
                    Text("Open Settings on a device that has your key and choose “Add a device”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let noticeMessage {
                    Section {
                        Text(noticeMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Restore your key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showPairing) {
                DevicePairingView(isPresented: $showPairing) {
                    onImported()
                    isPresented = false
                }
                .environmentObject(authService)
            }
            .sheet(isPresented: $showKeyCode) {
                KeyQRImportView(isPresented: $showKeyCode) {
                    onImported()
                    isPresented = false
                }
                .environmentObject(authService)
            }
        }
    }

    /// Shown when the key file proves the restored kit predates a rotation.
    ///
    /// The sheet deliberately stays open on this: the kit *did* install and
    /// older notes will open, so it is not an error, but closing straight to a
    /// library where recent notes fail one at a time would bury the one thing
    /// the user needs to act on.
    private static let staleKitNotice =
        "This kit was printed before your key last changed, so it does not include your "
        + "current key. Notes written since then will not open here. Print a fresh kit on the "
        + "web, or scan a key code instead."

    @MainActor
    private func restoreFromKit() async {
        isWorking = true
        errorMessage = nil
        noticeMessage = nil
        defer { isWorking = false }

        guard let userId = await authService.currentUserID() else {
            errorMessage = "You are signed out. Sign in and try again."
            return
        }
        do {
            let keyring = try RecoveryKit.importKit(kitText, userId: userId)
            guard KeyringStore.shared.store(keyring) else {
                errorMessage = "Could not save the key to this device."
                return
            }

            // A kit carries the whole keyring as it stood when it was printed,
            // so this usually finds nothing new. It earns its place on the kit
            // that is out of date: the file is sealed to the account's *current*
            // key, so a kit printed before the last rotation cannot open it, and
            // saying so here is the only warning the user gets that the kit they
            // just typed in is stale.
            let outcome = try? await KeyFileService.shared.restoreArchivedKeys(using: authService)
            if outcome?.activeIsStale == true {
                noticeMessage = Self.staleKitNotice
            }

            onImported()
            if noticeMessage == nil { isPresented = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
