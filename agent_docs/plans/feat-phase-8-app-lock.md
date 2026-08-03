# Plan: Phase 8 — Face ID / Touch ID Lock

Roadmap item: Phase 8 — Polish, "Face ID / Touch ID lock".

## 1. What the roadmap asks for, and what it is actually worth

The roadmap line is one bullet with no detail, so the first job is deciding what the feature is
*for*. It is easy to build this as though it were a security layer over the notes. It is not.

Notes are end-to-end encrypted. The DEK is sealed to a key pair in the Keychain, which is itself
protected by the device passcode and the Secure Enclave. An attacker holding a locked, stolen phone
already cannot read a note, with or without this feature. Adding a biometric gate does not encrypt
anything that was not already encrypted, does not rotate a key, and does not change what the server
stores.

What it does close is a different and much more ordinary threat: **an unlocked phone handed to
someone.** "Can I borrow your phone" / "let me show you this photo" / a device left face-up on a
desk mid-session. In that scenario the notes are decrypted, the session is live, and the only thing
between a stranger and every note in the account is the fact that they have to tap the Notes icon.

So the feature is a *screen* lock, scoped accordingly:

* It gates the app's UI, nothing else.
* It is **opt-in**. A user who does not want a second unlock on every glance should not get one.
* It must never be able to lock someone out of their own notes. This is the constraint that drives
  the biggest decision below.

## 2. Design decisions

### 2.1 `deviceOwnerAuthentication`, never `deviceOwnerAuthenticationWithBiometrics`

`LAPolicy.deviceOwnerAuthenticationWithBiometrics` is biometrics-only: no passcode fallback. Five
failed Face ID attempts put the sensor into `biometryLockout`, and a lockout is cleared by entering
the device passcode — which that policy will not offer. A cracked front camera, a face the sensor
stops recognising, sunglasses, a bandaged thumb: each of these would take the user's notes away
until they found another device.

`deviceOwnerAuthentication` prompts for biometrics first and falls back to the device passcode.
Anyone who can unlock the phone can unlock the app, which is exactly the right bar for a feature
whose whole purpose is the borrowed-phone case — the borrower has the phone, not the passcode.

The consequence for the UI is that a device with **no** biometric sensor is still lockable, so
`AppLockBiometry.none` is labelled "Passcode" rather than treated as unsupported. A device with no
passcode at all cannot be locked, and `canEvaluate()` returning false is what Settings renders as an
explanation instead of a toggle.

### 2.2 Turning the lock off is gated too

Enabling requires passing the check — this proves the check works before the user is ever standing
behind it, which is the difference between a security feature and a lockout bug.

Disabling requires passing it as well. Without that, the borrowed-phone attacker just walks into
Settings and flips the switch. The one thing deliberately *not* gated is `lockNow()`: making
something more protected never needs proof of identity.

### 2.3 The grace period is measured from `.background`, never `.inactive`

This is the trap in every implementation of this feature. Presenting the system biometric prompt
drops the scene to `ScenePhase.inactive`. If the auto-lock timer is wired to inactivity, then every
unlock attempt restarts the very timer it is racing — and, in the immediate-lock configuration,
each prompt re-locks the app behind itself.

So `AppLockService.didEnterBackground()` / `didBecomeActive()` are wired to `.background` and
`.active` only, and `NeutrinoNotesApp` explicitly ignores `.inactive` with a comment saying why.

The privacy shield is the exception that has to cover `.inactive`, because that is the phase iOS
takes the app-switcher snapshot in — a locked app that still hands over a readable picture of the
open note has not locked anything. `RootContentView` therefore receives `isSceneActive` (false for
both `.inactive` and `.background`) separately from the lock state.

A launch always starts locked when the feature is on, regardless of timeout: there is no
backgrounding timestamp to compare against, and a grace period that survived process death would be
a grace period across a reboot.

### 2.4 `BiometricAuthenticating`, so the state machine is testable

`LAContext.evaluatePolicy` needs real hardware and a real human, so a direct dependency would make
every branch of this feature — cancel, lockout, no passcode, success, timeout expiry — untestable.
The protocol has three members (`biometry`, `canEvaluate()`, `evaluate(reason:)`), the system
implementation is thin, and the fake in the tests drives all of them.

Two details live in `SystemBiometricAuthenticator` because they are easy to get wrong: a **fresh**
`LAContext` per evaluation (a reused one caches its success), and priming a throwaway context with
`canEvaluatePolicy` before reading `biometryType`, which is `.none` on an untouched context.

### 2.5 The preference is in `UserDefaults`, not the Keychain

The enabled flag and the timeout are a UI preference, not a secret, and the thing being protected is
the foreground app rather than data at rest. An attacker who can rewrite this app's defaults has
already lost the user the device — and the notes would still be ciphertext.

### 2.6 The lock screen is opaque

A blurred-but-visible note list still leaks titles, which are the most identifying thing in an
account. `LockScreenView` is a plain `systemBackground` cover.

### 2.7 Only the signed-in content is locked

`RootContentView` applies the lock to the `ContentView` branch, not to `LoginView`. A lock screen in
front of a login screen protects nothing.

## 3. Files

| File | What it is |
|------|------------|
| `NeutrinoNotes/Models/AppLockTimeout.swift` | The grace period; raw value is seconds, which is also the stored value |
| `NeutrinoNotes/Services/BiometricAuthenticator.swift` | `AppLockBiometry`, `AppLockAuthError`, the `BiometricAuthenticating` protocol, and the `LAContext` implementation |
| `NeutrinoNotes/Services/AppLockService.swift` | Lock state, the gated enable/disable flow, auto-lock, persistence |
| `NeutrinoNotes/Views/LockScreenView.swift` | The lock cover, `PrivacyShieldView`, and the `.appLocked(_:isSceneActive:)` modifier |
| `NeutrinoNotes/Views/SettingsView.swift` | The **App Lock** section: toggle, timeout picker, Lock Now |
| `NeutrinoNotes/NeutrinoNotesApp.swift` | Scene-phase wiring and the environment object |
| `NeutrinoNotes/Config/FeatureFlags.swift` | `appLock` |
| `project.yml` | `NSFaceIDUsageDescription` (required — the app crashes on first Face ID prompt without it) |

## 4. Tests

56 tests across four files, all offline and hardware-free.

* `AppLockTimeoutTests` — boundary behaviour of the grace period, including a backwards device
  clock, which must not *extend* it; the `UserDefaults` zero-default reading as "immediately".
* `AppLockServiceTests` — a fake authenticator and a hand-cranked clock cover: launch-locked,
  enable/disable both gated, no prompt when no passcode exists, cancel vs. lockout vs. failure,
  no prompt when already unlocked, per-trip grace periods, and the `.inactive`-shaped case of
  becoming active without ever having backgrounded.
* `BiometricAuthenticatorTests` — the sensor vocabulary and the error messages, plus that the real
  authenticator answers availability without prompting.
* `AppLockViewTests` — hosts the lock screen, the shield, the modifier in each presentation state,
  and Settings in all three of its branches (off / on / no passcode).

## 5. Not done

* **No per-note lock.** Drive has no per-file "locked" flag and the web app has no such concept, so
  a note marked private on iOS would be an invisible no-op everywhere else.
* **No app-specific passcode.** It would be a second secret to forget, weaker than the device
  passcode it duplicates, and it would need somewhere to live.
* **Keychain items are not re-scoped.** The keys already use the default accessibility; tightening
  them to `…ThisDeviceOnly` or a biometry-gated ACL is a separate change with real migration
  consequences for existing installs, and it is not what this roadmap line asks for.
* **Manual verification still needed on hardware.** The biometric prompt itself cannot be exercised
  in a unit test: enable the lock in Settings, background the app, and confirm the prompt appears,
  that cancelling leaves the lock in place, that the passcode fallback works, and that the app
  switcher shows the shield rather than the open note.
