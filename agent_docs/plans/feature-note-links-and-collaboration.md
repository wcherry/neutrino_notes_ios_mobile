# Plan: Note Links & Collaboration (iOS)

**Date:** 2026-08-09
**Status:** **Implemented** — all five phases, behind `FeatureFlags.noteLinks` and
`FeatureFlags.liveFileEvents`. Epic 23 remains scoped-but-unplanned (§5). Verification steps:
[`feature-note-links-and-collaboration-verification.md`](./feature-note-links-and-collaboration-verification.md).
Three things turned out differently from the plan below; they are marked **As built** where they
occur, and the ground truth in §2 has been corrected where the backend moved under it.
**Upstream:** `neutrino/agent_docs/notes-links-roadmap.md` (the web/server plan). This is our version of
it: what that roadmap means for this app, which is a different question, because **every server phase
in it has already shipped.**
**Roadmap epics covered:** Epic 20 (Internal Links), the honest half of Epic 24 (Real-time
collaboration), and a scoping decision on Epic 23 (Comments / Mentions / Activity).

---

## 1. What the web roadmap left us

The upstream roadmap has three phases: a generic links service, a shared file-events socket, and a
notes-frontend migration. Verified against `neutrino/` today:

| Upstream phase | State | Where |
|---|---|---|
| 1. Links service | **Shipped** | `src/links/{api,service,repository,dto}.rs`; `file_links` table |
| 2. Shared file events | **Shipped** | `src/shared/file_events/`, on `src/shared/presence_room.rs` |
| 3. Notes frontend migration | **Shipped** | `src/notes/` no longer exists; web uses drive + links + `useFileSync` |

So there is **no backend work in this plan and no backend work to ask for** (with one exception, §3.1).
Every phase below is a client of an endpoint that already exists and already has web callers to match.

### The contract, verified

| Endpoint | Shape |
|---|---|
| `GET /api/v1/links/{fileId}/backlinks` | `{ backlinks: [{ id, title, fileType }] }`. Requires read. 404 if the file is trashed. Trashed and unreadable *sources* are filtered out |
| `PATCH /api/v1/links/{fileId}` | Body `{ linkedTitles: [String] }`. Requires `owner`/`editor`, else 403. Returns the same `BacklinksResponse` — i.e. **incoming** links, not what you just sent. `linkedIds`/`linkedRanges` → 400 |
| `GET /api/v1/files/{id}/ws?token=…` | Binary relay. Varint message type: `1` awareness, `2` file-updated. **Signal only** — the payload never carries content. Requires read; 404 on a trashed file |

**Verified live** (a build of the current backend, against a copy of the dev database): a PATCH
naming a title nothing matches answers `{"backlinks":[]}` with no error — the silent-drop contract
this whole feature leans on — and a PATCH naming a real note makes the source appear in *that
note's* backlinks, not in the caller's. Sending both spellings of a title (§3.1) resolves the one
that exists and discards the other without complaint.

**As built:** the socket's token is written into the query string **verbatim**, not percent-encoded.
The server pulls it out by slicing the raw query (`api.rs`: `find(|kv| kv.starts_with("token="))`)
and never decodes it, so a helpfully-escaped token would arrive as gibberish and fail validation.
A JWT is base64url, so there is nothing to escape — `FileEventsClientTests` pins it, because a URL
builder's default behaviour is exactly the wrong one here.

`fileType` is one of `note`/`doc`/`sheet`/`slide`/`diagram`/`drawing`/`file`
(`src/links/service.rs::file_type_label`) — the same vocabulary as `NeutrinoAppLink.Kind`, which
matters in Phase 3.

---

## 2. Ground truth for *this* app

Verified against the code on 2026-08-09. Re-check before starting; don't trust this doc over `grep`.

- **Names are cleartext server-side; bodies are not.** That asymmetry is the only reason a
  server-resolved link graph is possible at all — the server matches `[[titles]]` against `files.name`,
  which it can already read. Same category as tag names (Epic 12) and the same reasoning as
  `feat-epic-11-search.md` §1.1.
- **There is no server-side title lookup any more.** The `GET /api/v1/drive/search` FTS endpoint that
  `feat-epic-11-search.md` describes **is gone** — `src/drive/search/` no longer exists, and the only
  thing under `src/search/` is the encrypted snapshot store (`/api/v1/search/index`, ciphertext the
  server cannot read). Resolving a title to a file id *for rendering and autocomplete* is entirely a
  client job here.
- **~~One request already lists every note.~~ Corrected 2026-08-09 (same day):** the whole-drive
  typed listing this plan was written against **no longer has a route.** The backend's listing
  redesign (`136efe4`, "fold root listing into /folders/{id}") removed `GET /api/v1/drive` and left
  `get_typed_contents` unreachable. What exists now: `/folders/{id}` (the root is addressed by the
  user's own id — `get_folder_contents` maps `folder_id == user_id` to root), `/recent`, `/starred`,
  `/trash`, `/shared-with-me`, `/shortcuts`.
  **Verified live** against a build of the current source: `/folders/{id}?type=note` filters files to
  notes exactly and returns subfolders *unfiltered* (a folder of 76 docs and 3 subfolders answers
  `files: 0, folders: 3`), and the root form answers 107 notes and 3 folders for this account. This
  is the endpoint the note index and the browser both ride on.
  **As built:** with no whole-drive listing to ask for, `NotesDriveService.loadNoteIndex()` walks the
  folder tree — one listing per folder, breadth-first, a 200-folder budget that logs when it bites,
  and a 60-second TTL so opening five notes doesn't walk it five times. Notes shared *with* this
  account are owner-scoped out of the walk and come from `/shared-with-me?type=note`, as before.
- **The tap-interception seam already exists.** `MarkdownView` installs an `OpenURLAction` that claims
  the `nn-footnote://` scheme ([MarkdownView.swift:34-38](NeutrinoNotes/Views/MarkdownView.swift#L34-L38)).
  A `nn-wikilink://` scheme costs nothing new architecturally.
- **The autocomplete pattern already exists.** `MarkdownSlashCommand.token(in:caret:)` +
  `MarkdownTextEditorController.showSlashCommandMenu` + `SlashCommandMenu` is a working
  caret-tracking popover in UTF-16 offsets. `[[` is the same shape.
- **The save path already holds plaintext.** `NoteEditorView.save()` has `text` in hand before
  `NoteContentService.saveContent` encrypts it, so "extract links before encryption" is free here —
  unlike on web, where it was a real constraint.
- **Notes has no CRDT and is not getting one in this plan.** `src/docs/collab/` (Yjs/`yrs`) is Docs'
  mechanism. The file-events relay is a doorbell, not a merge algorithm.

---

## 3. Two decisions to make before writing code

### 3.1 `.md` breaks every link between iOS and the web — fix it client-side

This app names notes `Meeting Notes.md` (`CreateNoteSheet.resolvedName` appends `.md` when the user
doesn't). The web names them `Untitled note` — no extension. The server resolves a title by exact
lowercased equality against `files.name` (`src/links/service.rs::update_links`).

Consequence: `[[Meeting Notes]]` typed on either client **silently resolves to nothing** for any note
created on iOS, and links written on the web to iOS-created notes are equally dead. Silently, because
an unresolvable title is a normal, non-error condition by design. A naive implementation of this plan
would ship a feature that appears to work and records almost no edges.

**Decision: send both spellings, and strip `.md` when matching locally.**

- `PATCH /links` gets `["Meeting Notes", "Meeting Notes.md"]` for a single `[[Meeting Notes]]`. Extra
  titles are free — the server drops non-matches without complaint, and self-links are excluded there.
- The local title index (Phases 2 and 4) keys each note under both its name and its name minus a
  trailing `.md`.
- No backend change, no rename of anyone's existing notes, and it keeps working if we later stop
  appending `.md`.

Rejected: asking the backend to strip extensions (a change to a shipped, web-facing resolver for one
client's naming habit); dropping the `.md` suffix here (fixes new notes only, orphans every existing
one, and is a user-visible change to a shipped flow). *Open question for the owner: should new notes
stop being named `.md` anyway, independently of this plan?*

### 3.2 `PATCH /links` sends note-body text to the server in the clear

The titles inside `[[…]]` are content typed into an end-to-end-encrypted body. Sending them is a real,
if narrow, leak:

- For a title that **resolves**, nothing new is disclosed — the edge is stored server-side anyway, and
  both endpoints of it are file names the server already holds.
- For a title that **doesn't** resolve, the server sees a phrase from inside an encrypted note and
  keeps nothing. It is still a phrase it never had before.

The web already does this, and the graph is worthless if it isn't shared between clients. **Ship it**,
behind `FeatureFlags.noteLinks`, and say so plainly in the feature's own documentation the way Epic 11
and Epic 22 did for their own leaks. The alternative — a device-local graph — abandons parity with the
web app, which is a stated roadmap goal, in exchange for hiding words that mostly turn out to be file
names the server can read.

---

## 4. Phases

Each phase is a branch and a PR. 1 → 2 → 3 → 4 are strictly ordered; 5 is independent of all of them.

### Phase 1 — Extraction and the graph write (no UI)

Branch: `feat/epic-20-note-links`

- **`Models/WikiLink.swift`** — pure, testable, UTF-16 offsets (its consumers are `UITextView` and
  `NSString`), same house style as `MarkdownChecklist`/`MarkdownSlashCommand`:
  - `static func matches(in text: NSString) -> [Match]`, `Match = (range: NSRange, title: String)` —
    pattern `\[\[([^\]]*)\]\]`, title trimmed, empties dropped. Phases 2 and 4 need the ranges.
  - `static func titles(in text: String) -> [String]` — deduplicated case-insensitively, first
    spelling wins, order preserved.
  - `static func requestTitles(in text: String) -> [String]` — `titles` plus the `.md` variant of each
    (§3.1). This is what goes on the wire.
  - Port the four upstream cases (`basic`, `empty`, `trims_whitespace`, `skips_empty_brackets`) from
    `web/packages/markdown/src/__tests__/index.test.ts`, so all three clients provably agree.
- **`Services/LinksService.swift`** — `getBacklinks(fileID:)`, `updateLinks(fileID:titles:)`. Copy
  `NotesDriveService`'s private `request`/`perform`/`authorized` helpers and its error enum shape;
  don't invent a new networking layer. The payload is camelCase and the shared
  `DriveDate.makeDecoder(convertFromSnakeCase: true)` is safe on it (no underscores to convert).
- **`Models/FileLink.swift`** — `FileLink { id, title, fileType }` with `fileType` mapped through
  `NeutrinoAppLink.Kind` where it matches, `nil` for `file`.
- **Editor wiring** — in `NoteEditorView.save()`, after `saveContent` succeeds:
  - skip when `isReadOnly` (the server would 403 anyway),
  - skip when the save went to the offline cache — the edit hasn't reached the server, so the graph
    would describe a version that doesn't exist there yet,
  - fire the PATCH detached from the save's status: **a failed link update must never render as a
    failed save.** Log it and let the next save carry the correct set; the request is idempotent.
  - Same treatment in `VersionHistoryService`-driven saves (`saveVersion` writes content too).
- **`SyncEngine`** — after a queued edit uploads successfully in `drain()`, PATCH the links extracted
  from the plaintext it just uploaded. That is the whole offline story: no second queue, no new
  persisted state, and the graph converges with the content.

**Acceptance:** editing a note that contains `[[Other Note]]` on the phone makes the backlink appear
in the web app's "Linked from" panel on Other Note, and vice versa. No iOS UI has changed yet.

### Phase 2 — Rendering and tapping a link

Branch: `feat/epic-20-link-rendering`

- **Model:** add `case wikiLink(title: String, resolved: Bool)` to `MarkdownInline`.
- **Parser:** the seam is `MarkdownParser.convertInline`'s `case let text as Text` — split that string
  on `WikiLink.matches` into `.text`/`.wikiLink` runs. Splitting `Text` (rather than pre-rewriting the
  source the way footnotes do) means inline code and fenced blocks are structurally immune:
  swift-markdown hands those over as `InlineCode`/`CodeBlock`, which this case never sees. `[[x]]`
  inside backticks must stay literal — verify with a test.
- **Renderer:** `nn-wikilink://<percent-encoded title>`, exactly parallel to `nn-footnote://`.
  Resolved links take the accent colour; unresolved ones take the secondary colour (the web's
  `wikiLinkBroken`), and both stay tappable here — see below.
- **Resolution:** a `WikiLinkIndex` (title-lowercased → `NoteItem`, both with and without `.md`) built
  from `NotesDriveService.allItems` + `sharedItems`, refreshed when the editor appears. `MarkdownView`
  needs the index injected; it is a pure input, so the renderer stays testable.
- **Tapping:**
  - resolved note → push the editor for that `NoteItem`;
  - resolved non-note (a doc, from a link the web wrote) → `NeutrinoAppLink.url(forFileID:mimeType:)`
    and hand it to the system, which is precisely what the Universal Links work built. Neutrino Docs
    takes it, Safari takes it otherwise;
  - **unresolved → offer to create it.** "Create *Project Plan*?" → `NoteContentService.createNote`
    in the current note's folder, then push it. The web leaves broken links inert; this is the one
    place where deviating from web parity is clearly right, because creating-by-linking is the whole
    point of wiki links and a phone is where you least want to go hunting for a New Note button.
    Disabled when read-only or offline.
- **Navigation is the awkward part.** `NoteEditorView` cannot push; `path` lives in `NotesView`, and
  Recents/Favorites/Tagged each own a *separate* `NavigationStack`. Add a small
  `NoteRouter: ObservableObject` (`@Published var open: NoteItem?`) injected per stack, each stack
  clearing it on consumption — the same hold-then-consume shape as `DeepLinkRouter`, which is already
  tested. Do **not** reuse `DeepLinkRouter` itself: an internal tap is not an inbound Universal Link,
  and overloading it would make the "did a link arrive before sign-in?" logic answer a question it
  isn't asking.
  **As built:** the router is reached through an `EnvironmentValues` key rather than an
  `@EnvironmentObject`, so a preview or a test that hosts the editor outside a stack gets a router
  nobody listens to instead of the crash a missing environment object would be. Recents, Favorites
  and Offline needed path-driven stacks in `ContentView` to push onto, and `OfflineView` needed a
  `navigationDestination(for: NoteItem.self)` — its rows had only ever pushed with destination
  closures, which a programmatic push cannot use.

**Acceptance:** `[[Meeting Notes]]` renders as a live link in Preview; tapping opens that note;
tapping an unknown title offers to create it.

### Phase 3 — The backlinks panel

Branch: `feat/epic-20-backlinks`

- "Linked from" under the note in Preview mode, hidden when empty (web parity), loaded on appear and
  refreshed after a successful `updateLinks`.
- Rows show the source title and a type chip for anything that isn't a note; tapping routes exactly as
  in Phase 2.
- Hidden entirely when offline or on a cached copy — there is nothing to show and nothing to cache.
  Available on shared notes: read access is all the endpoint requires.

### Phase 4 — `[[` autocomplete

Branch: `feat/epic-20-link-autocomplete`

- `WikiLink.token(in:caret:)` mirroring `MarkdownSlashCommand.token` — open on `[[`, filter on what
  follows, close on `]]`, on a newline, or when the caret leaves.
- Reuse `MarkdownTextEditorController`'s menu plumbing and `SlashCommandMenu`'s chrome; selecting a
  title completes `[[Title]]` and leaves the caret after it.
- Candidates come from the Phase 2 `WikiLinkIndex`, ranked prefix-first then substring, capped at ~8.
  Offer "Create *typed text*" as the last row when nothing matches (consistent with Phase 2).
- Display titles with `.md` stripped; insert the display form (the PATCH sends both anyway).

### Phase 5 — Live file events (Epic 24, the part that is real)

Branch: `feat/epic-24-file-events`. Independent of Phases 1–4.

- **`Services/FileEventsClient.swift`** — `URLSessionWebSocketTask` against
  `ws(s)://<host>/api/v1/files/{id}/ws?token=…` (scheme derived from `baseURL`; refresh the token
  before connecting, as the web does — a socket can't carry an `Authorization` header).
  - A `CollabVarint` helper (read/write, ~20 lines) to match `src/shared/collab_protocol`.
  - Send/receive type `2` with a JSON `{"clientId": "<per-launch uuid>"}` payload; **drop our own
    echo** by client id. Type `1` (awareness) is not used in this phase.
  - Reconnect with 2 s → 30 s backoff; tear the socket down on `scenePhase != .active` and reconnect
    on foreground, because iOS will kill it anyway and a zombie socket looks like a working one.
- **Editor integration**, guards mirroring the web's `dirtyRef`/`savingRef`:
  - broadcast after every successful online save;
  - on an inbound signal with `!isDirty` and not saving → reload metadata + content silently;
  - on an inbound signal while dirty → **do not clobber**. Show a "changed elsewhere" banner with a
    Reload action, and leave the user's text alone.
  - `SyncEngine`'s conflict rule stays the authority for anything queued offline. A doorbell doesn't
    get to overrule it.
- **Say what this is not.** No cursors, no character-level merge, no presence. Epic 24 stays open;
  what closes is "an edit made in the web app shows up here without a pull-to-refresh."

**Acceptance:** note open on the phone, edited in the web app → the phone's copy updates on its own,
within a second, and never while the user is mid-sentence.

---

## 5. Epic 23 (Comments / Mentions / Activity) — scoped, not planned

The endpoints exist and work: `GET|POST /files/{id}/comments`, `PATCH|DELETE .../{cid}`,
`POST .../{cid}/replies`, `GET /files/{id}/activity`, `GET /notifications` + `/notifications/ws`.

Two things must be settled before it can be planned, and neither is a coding question:

1. **Comment bodies are stored in plaintext.** `CreateCommentRequest.body: String` — no encryption
   anywhere in `src/drive/comments/`. A comment on an E2EE note is note content, and this app's entire
   proposition is that the server can't read note content. Either we ship it with an explicit
   in-UI disclosure, or we don't ship it. That is the owner's call, not an implementation detail.
2. **`anchor_json` is a range into the web's block model**, which this app does not have; anchored
   comments will not line up between clients without a shared addressing scheme.

Unanchored, disclosed comments plus a read-only activity feed is a defensible first slice. It needs its
own plan document.

---

## 6. Out of scope

- Any backend change (see §1 — and §3.1 deliberately avoids needing one).
- CRDT editing, live cursors, presence avatars — the rest of Epic 24.
- `linkedIds` / `linkedRanges`: the server returns 400 for both.
- Comments/mentions/activity implementation (§5).
- **Backfilling the graph.** Links are recorded only when a note is saved, so notes last edited before
  this ships contribute no edges until they're edited again. The web has the identical gap. Do not add
  a write-on-open backfill: it turns opening a note into a mutation, and it would fire on every note a
  user browses.

---

## 7. Feature flags

| Flag | Covers | Off behaviour |
|---|---|---|
| `FeatureFlags.noteLinks` | Phases 1–4 | `[[…]]` stays literal text, no PATCH, no panel, no menu |
| `FeatureFlags.liveFileEvents` | Phase 5 | No socket is opened; the editor behaves exactly as it does today |

Both default on when their phase merges, consistent with every prior epic here.

## 8. Testing

Unit tests per phase, in the established style (pure models tested directly; services seeded through
their `#if DEBUG` initializers with no token in the Keychain, as `SharingServiceTests` does):

- `WikiLinkTests` — the four ported upstream cases, plus dedup, `.md` variants, UTF-16 ranges,
  `[[x]]` inside inline code and fenced blocks staying literal.
- `LinksServiceTests` — request shape, 403/404 mapping, a failed PATCH leaving save status untouched.
- `MarkdownParserTests` / `MarkdownInlineRendererTests` — the new inline case and its URL scheme.
- `WikiLinkIndexTests` — `.md`-insensitive matching, shared notes included, self excluded.
- `FileEventsClientTests` — varint framing round-trip, own-echo suppression, backoff schedule.

A `feature-note-links-and-collaboration-verification.md` should carry the manual steps (two devices,
phone + web, offline queue, read-only shared note), following the convention set by the Epic 6 and
Epic 8 verification docs.

## 9. Open questions for whoever picks this up

- Should new notes stop being named `.md` (§3.1)? The plan works either way; this only affects how the
  titles users actually type read back to them.
- Duplicate titles: `update_links` builds a `HashMap` keyed on the lowercased name, so two notes called
  "Notes" resolve to whichever the server enumerated last — arbitrary but stable-ish. The local index
  needs a deliberate tie-break (recommend most-recently-modified) and the two will sometimes disagree.
  Confirm nobody minds before adding UI that implies precision.
- Is the My Notes root really unable to show folders (§2, aside)? If that's a live bug, it belongs in
  its own fix, but it changes what a user sees while testing Phase 2's navigation.
