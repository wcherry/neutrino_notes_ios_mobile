# Manual Verification: Epic 8 — Sync Engine

This feature is background-task-heavy and cannot be fully exercised by automated
unit tests. This checklist covers what a human tester needs to do on a real
simulator/device build. See the final report for exactly what was and wasn't
verified by the implementing agents before this.

## Prerequisites

- [ ] A build of this branch installed on a simulator or device, signed in with a
      real Neutrino account that has E2EE keys imported.
- [ ] A second device (or the web app) signed into the same account, so you can
      make a conflicting edit from "elsewhere."
- [ ] Network Link Conditioner (or simulator's network toggle, or airplane mode)
      available to simulate connectivity loss.

## Steps to Verify

### Happy Path — mutation survives a transient network blip

1. Open the Notes tab, create a folder.
2. Immediately toggle the device into Airplane Mode before the create-folder
   request would normally complete (you may need to be quick, or throttle the
   network first via Network Link Conditioner set to "100% Loss").
3. Confirm the folder still appears locally (optimistic UI, not reverted).
4. Turn Airplane Mode back off.
5. Open the Offline tab — confirm "Pending" count reflects the queued operation
   (or reaches 0 quickly as it drains automatically).
6. Reload the Notes tab / relaunch the app — confirm the folder is now present
   server-side (check the web app or another device) and was not lost.

### Happy Path — queue survives app termination

1. Repeat steps 1-2 above (create a folder or rename a note while offline).
2. Force-quit the app (don't just background it) while still offline.
3. Relaunch the app while still offline — open the Offline tab and confirm
   "Pending" still shows the queued operation (proves it was persisted to disk,
   not just in memory).
4. Restore connectivity and either wait for the periodic in-app sync or pull-to-
   refresh on the Offline tab. Confirm the operation completes and disappears
   from the pending list.

### Happy Path — background sync (milestone: "edits made on the phone appear on
the web version automatically")

1. Edit a note's content, let autosave fire (watch the "Saved" status).
2. Background the app (press Home / swipe up) without force-quitting.
3. On the web app or a second device, verify the edit appears without you having
   to reopen the iOS app. Note: this may take a real background execution window,
   which iOS schedules opportunistically — see the "known limitations" section
   below for how to force a background run for testing purposes.

### Edge Cases

#### Conflict — Keep Mine
1. On device A, open a note and start editing (don't let autosave finish, or
   pause on a slow connection).
2. On device B (or the web app), edit and save the same note.
3. On device A, let the edit attempt fire (or foreground the app) — confirm the
   "Sync Conflict" sheet appears with the note's name.
4. Tap "Keep Mine" — confirm device A's content becomes the server's version
   (check on device B / the web app after a refresh).

#### Conflict — Keep Server
1. Repeat the setup above.
2. Tap "Keep Server" — confirm the editor's text updates to device B's version,
   and the local edit is discarded.

#### Conflict — Fork
1. Repeat the setup above.
2. Tap "Keep Both (Fork)" — confirm a new note named
   `"<original name> (conflict copy).md"` appears in the same folder, containing
   the server's version, and the original note keeps your local edits (which
   then sync normally).

#### Permanently-failed entry
1. Force a non-retryable failure if possible (e.g. attempt an operation on an
   item that's been deleted server-side by another device first, causing a 404
   on drain) — confirm it does NOT sit forever "pending"; it's either dropped
   with a surfaced error (non-retryable) or, after repeated retryable failures,
   appears under "Needs Attention" in the Offline tab with a manual "Retry"
   button.

#### Delta sync doesn't clobber unrelated in-flight UI state
1. Open a folder with several notes, and while the listing is visible, edit or
   rename a note. Trigger a background/foreground sync (e.g. switch tabs and
   back). Confirm the list doesn't visibly "flicker" or lose your just-made
   local change while syncing.

## Known limitations of this implementation's testability

- **BGTaskScheduler cannot be triggered on demand from normal usage** — iOS
  decides when to actually run a background task based on device state,
  battery, and usage patterns; it will not reliably fire within a short manual
  test window. To force a run for testing, attach lldb to the running app on a
  simulator/device and execute:
  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.neutrino.notes.sync"]
  ```
  This is Apple's own documented debugging technique but is a private/internal
  API — it's not something this implementation itself can invoke, and it wasn't
  runnable from the CLI-only environment this feature was built in. A tester
  with Xcode + a running debug session should use it to confirm the handler at
  least executes and calls `setTaskCompleted`.
- The `Info.plist` `UIBackgroundModes`/`BGTaskSchedulerPermittedIdentifiers`
  entries and `AppDelegate` registration were verified by code review and by the
  fact the project still builds and passes `plutil -lint` — not by an actual
  observed background execution, which requires a real device/simulator session
  outside this environment.
