import SwiftUI
import NeutrinoAuth
import NeutrinoUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appLock: AppLockService

    @State private var hasKeys = KeyImportService.hasStoredKeys()
    @State private var showKeyImport = false
    @State private var showKeyRestore = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Text("Settings")
                        .font(.largeTitle)
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 32)
            }

            Section("Encryption Key") {
                if hasKeys {
                    Label("Encryption Key: Imported \u{2713}", systemImage: "key.fill")
                        .foregroundStyle(.primary)

                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Text("Remove Keys")
                    }
                    .alert("Forget this device's key?", isPresented: $showRemoveConfirmation) {
                        Button("Forget", role: .destructive) {
                            KeyImportService.removeKeys()
                            hasKeys = false
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        // No server-side copy exists, so this is only safe if the
                        // key survives somewhere else. Say so rather than implying
                        // it can be fetched back.
                        Text("This device will no longer be able to read your encrypted notes. Your key is not deleted — you can restore it from your recovery kit, or from another device that still has it. If neither exists, your notes become unreadable permanently.")
                    }
                } else {
                    // The only two ways in, both offline: the printed recovery
                    // kit, or a device that already holds the key. There is no
                    // "create one" here — this account's files are sealed to an
                    // identity that already exists.
                    Button {
                        showKeyRestore = true
                    } label: {
                        Label("Restore My Key", systemImage: "key.horizontal")
                    }
                    .sheet(isPresented: $showKeyRestore) {
                        hasKeys = KeyImportService.hasStoredKeys()
                    } content: {
                        KeyRestoreView(isPresented: $showKeyRestore) {
                            hasKeys = KeyImportService.hasStoredKeys()
                        }
                        .environmentObject(authService)
                    }

                    // Manual import stays for key files exported by a build that
                    // predates versioning.
                    Button {
                        showKeyImport = true
                    } label: {
                        Label("Import Key File", systemImage: "key")
                    }
                    .sheet(isPresented: $showKeyImport) {
                        hasKeys = KeyImportService.hasStoredKeys()
                    } content: {
                        KeyImportView(isPresented: $showKeyImport)
                    }
                }
            }

            if FeatureFlags.appLock {
                appLockSection
            }

            Section {
                Button(role: .destructive) {
                    authService.logout()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - App Lock

    /// Phase 8 app lock. The toggle has no local state on purpose: `appLock.isEnabled` only flips
    /// after the owner check passes, so a cancelled Face ID prompt springs the switch back on its
    /// own rather than needing to be reverted by hand.
    @ViewBuilder
    private var appLockSection: some View {
        Section {
            if appLock.isAvailable {
                Toggle(isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { newValue in Task { await appLock.setEnabled(newValue) } }
                )) {
                    Label("Require \(appLock.biometry.label)", systemImage: appLock.biometry.iconName)
                }
                .disabled(appLock.isAuthenticating)

                if appLock.isEnabled {
                    Picker("Lock After", selection: Binding(
                        get: { appLock.timeout },
                        set: { appLock.setTimeout($0) }
                    )) {
                        ForEach(AppLockTimeout.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    Button {
                        appLock.lockNow()
                    } label: {
                        Label("Lock Now", systemImage: "lock.fill")
                    }
                }
            } else {
                Label("Set a device passcode to use app lock", systemImage: "exclamationmark.lock")
                    .foregroundStyle(.secondary)
            }

            if let message = appLock.lastError?.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("App Lock")
        } footer: {
            Text("Your notes are always encrypted. App lock adds \(appLock.biometry.label) in front of the app itself, so an unlocked phone still can't be handed over open.")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
            .environmentObject(AppLockService())
    }
}
