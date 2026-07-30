# Plan: Epic 8 — Sync Engine

Branch: `feature/epic-8-sync-engine`

## 1. What's changing and why

Today every mutation in `NotesDriveService` (create folder, rename, move, delete,
restore, empty trash) is optimistic: it updates local state, fires a detached
`Task {}` against the API, and on failure **reverts** the local change and drops it
on the floor. `NoteContentService.saveContent` blindly overwrites the server copy —
no version check, so two devices editing the same note silently clobber each other.
Autosave lives entirely in `NoteEditorView`'s in-memory debounce Task; if the app is
killed or the final `onDisappear` save fails, the edit is gone. There is no disk
persistence, no background execution, and no delta sync — every `loadSection` call
wholesale-replaces the cached listing for a parent.

Epic 8 replaces "revert and lose the change" with "revert-or-not, but always queue
and retry," adds a durable on-disk retry queue, adds real `BGTaskScheduler`-driven
background sync, adds three-way conflict detection/resolution, and turns
`loadSection`'s wholesale replace into a watermark-based diff. Epic 9 (Offline
Editing, not in scope) will build local body caching on top of the persistence
layer this epic introduces, so the queue/watermark store is deliberately written as
a small reusable component rather than something wedged only into today's call
sites.

No `mvp.md` exists anywhere in this repo (confirmed via `find`), so there is no
sibling Drive-MVP reference doc to defer to for a delta-endpoint design — the
client-side watermark approach in the brief is what's implemented. Confirmed no
server-side changes-feed endpoint is used anywhere in the current client code
(only full-listing endpoints).

## 2. Product decisions already made (implementing as-is, not re-litigating)

- **Conflict** = server `modifiedAt` for a note has advanced past this device's last
  known watermark for that note, **and** this device has unsynced local edits for
  it. Resolution is always one of exactly three explicit user choices — Keep Mine /
  Keep Server / Fork (`"<Title> (conflict copy).md"` in the same folder, server
  content forked off, local edits kept in the original and synced normally). No
  last-write-wins, no auto-merge.
- Full `BGTaskScheduler` integration now: `AppDelegate` via
  `@UIApplicationDelegateAdaptor`, `BGProcessingTask` (not `BGAppRefreshTask` — see
  §4), registered before `didFinishLaunchingWithOptions` returns, background
  handler invokes the same `runSync()` routine the foreground path uses.

## 3. Layers affected

- **Backend**: none — no separate backend repo; this app has no server of its own
  (per `road_map.md`, it reuses Neutrino Drive's existing APIs unchanged).
- **iOS app (Swift/SwiftUI)**: new `SyncEngine` service, new persistence layer, new
  `AppDelegate`, `Info.plist` additions, refactor of `NotesDriveService` and
  `NoteContentService`, changes to `NoteEditorView`, `OfflineView`, `ContentView`
  wiring untouched (tab already exists), `NeutrinoNotesApp.swift`, `FeatureFlags`,
  and a new `Codable` conformance on `NoteItem`.
- **Design**: a new three-choice conflict resolution sheet, and turning the
  placeholder `OfflineView` into a real sync-status screen (pending count, last
  synced time, conflicts list). Both are small, in-house SwiftUI, consistent with
  existing screens like `NoteEditorView.loadErrorView`.
- **Tests**: new `SyncEngineTests.swift`; updates to `NotesDriveServiceTests.swift`
  and `NoteContentServiceTests.swift` for the new enqueue-on-failure behavior;
  `NoteItem` Codable round-trip coverage.

## 4. Architecture

### 4.1 Persistence — `SyncPersistence` (new file, `Services/SyncPersistence.swift`)

Plain `Codable` structs written via `FileManager` to
`Application Support/NeutrinoNotesSync/` (created with
`.applicationSupportDirectory`, excluded from iCloud backup via
`isExcludedFromBackup` resource value since it's a transient retry cache, not user
data of record — the server is the source of truth). Two files, each written
atomically (`Data.write(options: .atomic)`):

- `queue.json` — `[SyncQueueEntry]`, the retry queue.
- `watermarks.json` — `[String: Date]`, item ID → last-known server `modifiedAt`,
  used for both delta sync and conflict detection.

No new SPM dependency — this is the same lightweight style already used elsewhere
in the app (`KeychainService` wraps the Keychain APIs directly; nothing here
justifies CoreData/SwiftData, and SwiftData is iOS 17+ which is above this app's
16.0 floor).

### 4.2 Retry queue — `SyncQueueEntry` (Codable struct, not an enum-with-payload,
to keep persistence trivial)

```swift
enum SyncOperationKind: String, Codable {
    case createFolder, renameFolder, renameFile, trashFile, trashFolder,
         permanentDeleteFile, permanentDeleteFolder, moveFile, moveFolder,
         restoreFile, restoreFolder, emptyTrash, saveNoteContent
}

struct SyncQueueEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var kind: SyncOperationKind
    var itemID: String?              // target item; nil only for emptyTrash
    var placeholderID: String?       // createFolder: local optimistic ID to reconcile
    var newName: String?             // rename
    var previousName: String?        // rename revert-on-permanent-failure
    var newParentID: String?         // move; nil is a valid "move to root"
    var previousParentID: String?    // move revert
    var itemSnapshot: NoteItem?      // trash/restore/permanentDelete revert
    var trashSnapshot: [NoteItem]?   // emptyTrash revert
    var encryptedContentBase64: String?  // saveNoteContent: ciphertext, already
                                          // E2EE-encrypted at enqueue time — safe
                                          // to persist to disk unencrypted-at-rest
                                          // wrapper, since it's already ciphertext.
                                          // The DEK itself is never persisted.
    var fileName: String?
    var mimeType: String?
    var baseModifiedAt: Date?        // watermark this save was staged against —
                                      // used for conflict detection before retry
    var createdAt: Date = Date()
    var attemptCount: Int = 0
    var nextAttemptAt: Date = Date()
    var lastError: String?
}
```

`kind` disambiguates which fields are meaningful; unused fields are simply nil.
`NoteItem` gains `Codable` conformance (all its stored properties are already
Codable-compatible: `String`, `Date`, `Bool`, `Int64?`, and the `ItemType` enum
gets `Codable` too) — a small, low-risk addition needed for `itemSnapshot`.

**Backoff**: exponential with cap — `nextAttemptAt = now + min(2^attemptCount * 5s, 15min)`,
capped at e.g. 8 attempts before an entry is surfaced as a permanent failure in the
Offline tab (still retryable manually) rather than retried forever silently.

**Retryable vs. not**: `networkError` and `serverError(5xx)` are retryable (queued,
optimistic UI state is left as-is — the brief explicitly allows combining "revert
if you want" with "still queue"; here we choose *not* to revert so the user doesn't
see their edit flicker away, since it's still queued and will resolve).
`serverError(4xx)` (other than a future 409 conflict signal), `decodingError`, and
`notAuthenticated` are not retryable — these revert the optimistic state (today's
existing behavior) and surface `self.error`, since retrying a doomed request
forever is worse than telling the user now.

### 4.3 `SyncEngine` (new file, `Services/SyncEngine.swift`)

`@MainActor final class SyncEngine: ObservableObject`. Published state:
`pendingCount: Int`, `isSyncing: Bool`, `lastSyncedAt: Date?`, `lastError: String?`,
`conflicts: [SyncConflict]`.

Holds `weak var authService: AuthService?`, `weak var notesDriveService:
NotesDriveService?`, `weak var noteContentService: NoteContentService?`, wired the
same way `AuthService` is wired into the other two today (`NeutrinoNotesApp`'s
`.task`).

The actual network calls the queue drains through are **injectable** (a small
internal protocol/closure bundle, not hardcoded to `URLSession`) so
`SyncEngineTests` can fake success/failure/backoff deterministically without
touching the network — the existing service tests get away with not doing this
because they only assert synchronous optimistic-update state before the
background `Task` resolves; a queue-draining engine can't take that shortcut since
draining *is* the behavior under test.

Core routine `runSync() async` (**the one routine both foreground and background
paths call — no duplicated sync logic**):
1. Drain due entries from the retry queue (oldest first): for `saveNoteContent`
   entries, re-check `baseModifiedAt` against the freshly-known server
   `modifiedAt` for that item before pushing — if the server has moved on, raise a
   `SyncConflict` instead of overwriting, and leave the entry queued (not retried)
   until the conflict is resolved. Otherwise attempt the operation once; success
   reconciles `NotesDriveService`/watermarks, failure reschedules with backoff or
   reverts per §4.2.
2. Delta-sync each currently-relevant parent folder: fetch the listing, diff
   against `allItems` by `modifiedAt` per ID (new/changed → upsert, missing →
   remove, unchanged → leave alone) instead of `NotesDriveService.loadSection`'s
   current wholesale clear-and-replace. Update the watermark store for every item
   touched.
3. Update `lastSyncedAt`, persist queue/watermark state.

Foreground trigger points: app launch, `scenePhase` becoming `.active`, and a
lightweight periodic in-app timer (every 2 minutes) while foregrounded — plus an
immediate best-effort attempt at the moment any mutation is enqueued (this is what
makes the common "online" case feel identical to today's behavior; the queue only
matters when that immediate attempt fails).

### 4.4 Background execution

- `Info.plist`: `UIBackgroundModes` → `processing`; `BGTaskSchedulerPermittedIdentifiers`
  → `["com.neutrino.notes.sync"]`.
- **`BGProcessingTask`, not `BGAppRefreshTask`**: refresh tasks are budgeted for
  short, best-effort metadata refreshes (seconds); this work — draining a queue of
  encrypted-body uploads/downloads and running delta sync across folders — can
  legitimately run longer and isn't "refresh the feed" shaped. `BGProcessingTask`
  is the documented fit for exactly this ("upload/download... may take minutes").
  `requiresNetworkConnectivity = true`, `requiresExternalPower = false` (this
  should run readily, not just when charging).
- New `AppDelegate.swift`: `application(_:didFinishLaunchingWithOptions:)` calls
  `BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.neutrino.notes.sync", using: nil)`
  synchronously, before returning — registration must happen unconditionally at
  process launch per Apple's requirement (it cannot be gated behind the
  `syncEngine` feature flag or made conditional on auth state). The handler:
  sets `task.expirationHandler` to cancel the in-flight `runSync()` `Task` and call
  `setTaskCompleted(success: false)`; on normal completion calls
  `setTaskCompleted(success:)` and schedules the next `BGProcessingTaskRequest`
  (`earliestBeginDate = now + 15min`, matching typical BG budget expectations).
- `NeutrinoNotesApp.swift` adds `@UIApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate`. Because BGTaskScheduler registration must exist before any
  `@StateObject` is guaranteed constructed, `SyncEngine` is exposed as a
  `SyncEngine.shared` singleton — the one deliberate exception to this codebase's
  per-instance-`@StateObject` pattern — constructed lazily and referenced both by
  `@StateObject private var syncEngine = SyncEngine.shared` (for the environment
  object / SwiftUI observation) and by `AppDelegate`'s background handler, so
  there's exactly one instance and one code path.
- A `BGProcessingTaskRequest` is also submitted when the scene backgrounds
  (`scenePhase == .background` in `ContentView`/root), and after each foreground
  `runSync()` completes, so there's always a next background attempt scheduled.

### 4.5 Conflict detection & resolution UX

`SyncConflict` (in-memory, not persisted — resolving it requires either the live
editor's plaintext or a queued ciphertext entry, both already-available inputs):

```swift
struct SyncConflict: Identifiable {
    let id: UUID
    let itemID: String
    let itemName: String
    let parentID: String?
    let serverModifiedAt: Date
    let detectedAt: Date
}
```

Two detection paths, both covered by this epic's scope (no persisted local body
cache exists yet — that's Epic 9 — so "local unsynced edits" only exist in these
two places today):

1. **Live editor conflict**: `NoteEditorView` already observes
   `NotesDriveService` via `@EnvironmentObject`. It now also observes `SyncEngine`.
   On each autosave attempt (and on `scenePhase` becoming active while the editor
   is open), it compares the item's current `modifiedAt` in
   `notesDriveService.allItems` (kept fresh by delta sync, §4.3 step 2) against the
   `modifiedAt` it loaded with. If that has advanced **and** `isDirty` is true, it
   blocks the save, asks `SyncEngine` to register a `SyncConflict`, and presents
   the resolution sheet instead of silently saving.
2. **Queued-save conflict**: during queue drain (§4.3 step 1), a `saveNoteContent`
   entry whose `baseModifiedAt` is behind the freshly-fetched server `modifiedAt`
   raises a conflict instead of draining. Surfaced in the Offline tab's conflict
   list (so it's resolvable even if the editor isn't open).

Resolution (`ConflictResolutionView`, new file, presented as a `.sheet` from
either `NoteEditorView` or `OfflineView`):
- **Keep Mine** — push local plaintext (editor case) or the queued ciphertext
  (queue case) via `NoteContentService.saveContent`/direct ciphertext PUT,
  overwriting server; update watermark; clear the conflict.
- **Keep Server** — `NoteContentService.loadContent` the server version, replace
  local editor text (if open) or drop the stale queue entry; update watermark;
  clear the conflict.
- **Fork** — `NoteContentService.loadContent` the server version,
  `NoteContentService.createNote(name: "<Title> (conflict copy).md", parentID:)`
  with that content, then proceed to push the local edits to the *original* note
  as a normal save (same as Keep Mine on the original); update watermarks for
  both notes; clear the conflict.

### 4.6 `OfflineView` becomes the sync status screen

Replaces the static "Offline" text with: pending queue count, last synced time,
a list of unresolved conflicts (tap → resolution sheet), and any permanently-failed
entries (§4.2 cap) with a manual "Retry" action. This is explicitly a UI nicety per
the brief, not a hard requirement — kept simple, matching `NoteEditorView`'s
existing empty/error-state visual language.

### 4.7 Feature flag

`FeatureFlags.syncEngine: Bool = true` — gates the periodic foreground trigger,
background task *submission* (not registration, which must stay unconditional per
§4.4), and the conflict UI. When false, mutations still enqueue (so nothing is
silently lost) but the queue only drains via the existing immediate-attempt path,
i.e. behavior degrades to "no background sync, no periodic retry sweep, no
conflict prompts" rather than fully reverting to today's lossy behavior.

## 5. Risks & edge cases

- **BGTaskScheduler is effectively unverifiable in this environment.** The
  simulator's `_simulateLaunchForTaskWithIdentifier:` lldb trick can be used
  manually if the app is later run in Xcode, but it cannot be driven from this
  CLI/agent environment — the final report will flag this as unverified beyond
  code review and unit tests of `runSync()` in isolation.
- **Conflict detection on the queued-save path only fires during a queue drain** —
  if the app never comes back online / foreground/background sync never runs, a
  stale queued save just stays queued (correct — not silently applied).
- **`itemSnapshot`/`trashSnapshot` growing `SyncQueueEntry`** — emptyTrash could in
  theory persist a large trash listing to disk; acceptable for this app's expected
  note counts, flagged rather than engineered around.
- **Making `NoteItem` Codable** touches a shared model used across the app —
  low-risk (pure additive conformance) but worth double-checking nothing currently
  relies on `NoteItem` *not* being Codable (nothing does, per grep).
- **Existing `NotesDriveServiceTests`** assert synchronous optimistic state and
  don't await the background `Task` — the refactor must preserve that the
  synchronous optimistic update still happens before `SyncEngine` is even
  consulted, so those tests keep passing unmodified where possible; new tests
  cover the enqueue-on-failure path explicitly.
- **Multipart upload retry** for `saveNoteContent` reuses the already-encrypted
  ciphertext captured at enqueue time rather than re-encrypting on retry — this
  avoids persisting plaintext or the DEK to disk, but means a retried save always
  reflects the text as of the *original* save attempt, not any further edits made
  while offline (acceptable: further edits reschedule autosave and enqueue their
  own newer entry, superseding the older one for the same item).

## 6. Specialists needed

- **frontend-developer** (this repo has no separate backend — all work is
  iOS Swift/SwiftUI, so it owns the full client stack): `SyncEngine`,
  `SyncPersistence`, `SyncQueueEntry`/`SyncConflict` models, `NoteItem` Codable
  conformance, `AppDelegate`, `NeutrinoNotesApp` wiring, `Info.plist` changes,
  refactor of `NotesDriveService` and `NoteContentService`, `FeatureFlags` entry,
  and the data/logic side of `NoteEditorView`'s conflict integration.
- **ui-designer**: `ConflictResolutionView` (three-choice sheet) and the new
  `OfflineView` sync-status layout (pending/last-synced/conflicts/failed lists),
  matching existing visual language (SF Symbols, `.secondary` text, the
  `loadErrorView` pattern in `NoteEditorView`).
- **test-writer**: `SyncEngineTests.swift` (queue persistence round-trip, backoff
  math, conflict detection logic, injectable-network drain behavior); updates to
  `NotesDriveServiceTests.swift` and `NoteContentServiceTests.swift` for
  enqueue-on-failure; `NoteItem` Codable round-trip test.

## 7. Acceptance criteria

- A mutation that fails due to a transient network error is retried automatically
  (queue drain) rather than being reverted and lost.
- The retry queue survives an app relaunch (persisted to disk, redrained on next
  launch/foreground/background sync).
- `NotesDriveService.loadSection` no longer wholesale-replaces a parent's items on
  every call — unchanged items (by `modifiedAt`) are left alone.
- Opening a note whose server `modifiedAt` has advanced past the local watermark
  while there are unsynced local edits prompts Keep Mine / Keep Server / Fork —
  never silently overwrites either side.
- `BGTaskScheduler.shared.register` is called before `didFinishLaunchingWithOptions`
  returns, using identifier `com.neutrino.notes.sync`, and the handler invokes the
  same `runSync()` used in foreground.
- `cargo test` is N/A (no Rust in this repo); `xcodebuild test` (unit test target)
  passes, including new `SyncEngineTests`.
- No new SwiftPM dependency added.

## 9. API contract (binding — test-writer and frontend-developer both build against this exactly, to avoid drift between red-phase tests and implementation)

```swift
// MARK: - Services/SyncModels.swift

enum SyncOperationKind: String, Codable {
    case createFolder, renameFolder, renameFile, trashFile, trashFolder,
         permanentDeleteFile, permanentDeleteFolder, moveFile, moveFolder,
         restoreFile, restoreFolder, emptyTrash, saveNoteContent
}

struct SyncQueueEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: SyncOperationKind
    var itemID: String?
    var placeholderID: String?
    var newName: String?
    var previousName: String?
    var newParentID: String?
    var previousParentID: String?
    var itemSnapshot: NoteItem?
    var trashSnapshot: [NoteItem]?
    var encryptedContentBase64: String?
    var fileName: String?
    var mimeType: String?
    var baseModifiedAt: Date?
    var createdAt: Date = Date()
    var attemptCount: Int = 0
    var nextAttemptAt: Date = Date()
    var lastError: String?

    static let maxAttempts = 8

    /// Exponential backoff capped at 15 minutes: min(2^attemptCount * 5s, 15min).
    static func backoffInterval(forAttempt attemptCount: Int) -> TimeInterval

    // Pure factories — these are what NotesDriveService/NoteContentService call from their
    // existing catch blocks, and are directly unit-testable without any network faking.
    static func createFolder(placeholderID: String, name: String, parentID: String?) -> SyncQueueEntry
    static func renameFolder(itemID: String, newName: String, previousName: String) -> SyncQueueEntry
    static func renameFile(itemID: String, newName: String, previousName: String) -> SyncQueueEntry
    static func trashFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func trashFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func permanentDeleteFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func permanentDeleteFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func moveFile(itemID: String, newParentID: String?, previousParentID: String?) -> SyncQueueEntry
    static func moveFolder(itemID: String, newParentID: String?, previousParentID: String?) -> SyncQueueEntry
    static func restoreFile(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func restoreFolder(itemID: String, snapshot: NoteItem) -> SyncQueueEntry
    static func emptyTrash(snapshot: [NoteItem]) -> SyncQueueEntry
    static func saveNoteContent(itemID: String, encryptedContentBase64: String, fileName: String,
                                 mimeType: String, baseModifiedAt: Date?) -> SyncQueueEntry
}

struct SyncConflict: Identifiable, Equatable {
    let id: UUID
    let itemID: String
    let itemName: String
    let parentID: String?
    let serverModifiedAt: Date
    let localModifiedAt: Date?
    let detectedAt: Date
}

enum ConflictChoice { case keepMine, keepServer, fork }

enum ConflictLocalSource {
    case editorText(String, dek: Bytes)   // live editor has plaintext + dek in memory
    case queuedCiphertext                  // resolve using whatever the queue entry already has
}

struct ConflictResolutionOutcome {
    var updatedLocalText: String?   // set on keepServer/fork — caller (editor) should refresh its text
    var forkedItem: NoteItem?       // set on fork
}
```

```swift
// MARK: - Services/SyncPersistence.swift

final class SyncPersistence {
    static let shared: SyncPersistence   // Application Support/NeutrinoNotesSync/
    init(directoryURL: URL)              // tests inject a temp directory
    func loadQueue() -> [SyncQueueEntry]
    func saveQueue(_ entries: [SyncQueueEntry])
    func loadWatermarks() -> [String: Date]
    func saveWatermarks(_ watermarks: [String: Date])
}
```

```swift
// MARK: - Services/SyncEngine.swift

/// Executes one queued operation against the real Drive/Note APIs. SyncEngine's default
/// executor wraps notesDriveService/noteContentService; SyncEngineTests inject a fake so
/// queue-draining, backoff, and conflict logic are testable without touching the network.
protocol SyncOperationExecuting {
    func perform(_ entry: SyncQueueEntry) async throws -> SyncOperationOutcome
    /// Lightweight current-modifiedAt lookup used to pre-check a saveNoteContent entry
    /// for conflicts before draining it. nil = item no longer exists server-side.
    func currentModifiedAt(forItemID itemID: String) async throws -> Date?
}

struct SyncOperationOutcome {
    var createdItem: NoteItem?
    var updatedModifiedAt: Date?
}

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var pendingCount: Int
    @Published private(set) var isSyncing: Bool
    @Published private(set) var lastSyncedAt: Date?
    @Published var lastError: String?
    @Published private(set) var conflicts: [SyncConflict]
    @Published private(set) var failedEntries: [SyncQueueEntry]   // exceeded maxAttempts

    weak var authService: AuthService?
    weak var notesDriveService: NotesDriveService?
    weak var noteContentService: NoteContentService?

    init(persistence: SyncPersistence = .shared, executor: SyncOperationExecuting? = nil,
         clock: @escaping () -> Date = Date.init)

    func enqueue(_ entry: SyncQueueEntry)
    func runSync() async                       // the one routine both foreground + background call
    func retryNow(_ entry: SyncQueueEntry) async

    func resolve(_ conflict: SyncConflict, choice: ConflictChoice,
                 localSource: ConflictLocalSource) async throws -> ConflictResolutionOutcome

    var queueSnapshot: [SyncQueueEntry] { get }
}
```

Retryable-error classification (§4.2) is implemented as a small internal predicate SyncEngine applies to whatever `Error` `perform(_:)` throws — `NotesDriveError.networkError`/`.serverError(5xx)` and `NoteContentError.networkError`/`.serverError(5xx)` are retryable; everything else is not. This predicate is unit-testable in isolation.

`NoteItem` and `NoteItem.ItemType` gain `Codable` conformance directly in `Models/NoteItem.swift` (additive, auto-synthesized — no custom `init`/`encode` needed).

## 10. Explicitly out of scope (deferred to Epic 9 or later)

- Persisted local body cache for true offline editing (Epic 9).
- Any server-side delta/changes-feed endpoint (none exists; not this app's repo to
  add one to).
- Auto-merge / diffing of Markdown text content.
