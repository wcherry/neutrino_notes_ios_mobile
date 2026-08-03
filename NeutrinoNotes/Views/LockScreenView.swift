import SwiftUI

// MARK: - LockScreenView

/// The full-screen cover shown while the app is locked.
///
/// It is opaque on purpose — the point of the lock is that the notes underneath are not readable,
/// and a blurred-but-visible list still leaks titles.
struct LockScreenView: View {
    @EnvironmentObject var appLock: AppLockService

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: appLock.biometry.iconName)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Neutrino Notes is Locked")
                        .font(.title2.weight(.semibold))

                    Text("Unlock with \(appLock.biometry.label) to see your notes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let message = appLock.lastError?.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appLock.isAuthenticating)
            }
            .padding(.horizontal, 40)
        }
        // One automatic attempt on appear, so the common case is a glance at the phone rather than
        // a tap. The button is what covers a cancel, a lockout, or a second attempt.
        .task {
            await appLock.unlock()
        }
    }
}

// MARK: - PrivacyShieldView

/// What replaces the app's content while it is off screen.
///
/// iOS snapshots the window when the app is backgrounded and shows that snapshot in the app
/// switcher, where it survives the lock. Without this, a locked app still hands over a readable
/// picture of whatever note was open.
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            Image(systemName: "lock.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityLabel("Neutrino Notes is hidden")
        }
    }
}

// MARK: - App Lock Modifier

private struct AppLockModifier: ViewModifier {
    @ObservedObject var appLock: AppLockService

    /// Whether the scene is currently on screen. Driven by the app's `scenePhase`, not read here,
    /// because the shield has to cover `.inactive` as well — that is the phase the snapshot is
    /// taken in.
    let isSceneActive: Bool

    func body(content: Content) -> some View {
        ZStack {
            content

            if appLock.shouldPresentLockScreen {
                LockScreenView()
                    .transition(.opacity)
            } else if appLock.shouldShieldContent && !isSceneActive {
                PrivacyShieldView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
    }
}

extension View {
    /// Covers this view with the lock screen while locked, and with the privacy shield while the
    /// scene is off screen. Apply once, at the root of the authenticated content.
    func appLocked(_ appLock: AppLockService, isSceneActive: Bool) -> some View {
        modifier(AppLockModifier(appLock: appLock, isSceneActive: isSceneActive))
    }
}

#Preview("Locked") {
    LockScreenView()
        .environmentObject(AppLockService())
}

#Preview("Privacy Shield") {
    PrivacyShieldView()
}
