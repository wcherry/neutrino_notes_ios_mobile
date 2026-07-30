# Plan: Epic 12 — Organization

Branch: `feat/epic-12-organization` (from `main`, after Epic 10)

## 1. What the roadmap asks for, and what actually exists

> Features: Favorites, Pinning, Recent Notes, Trash, Tags, Nested folders
> Milestone: Organization matches the web application.

Checked against the backend (`neutrino/src/drive/filesystem/`, `neutrino/src/drive/tags/`) and the
web client (`neutrino/web/apps/web/src/app/(apps)/drive/`, `.../notes/`):

| Feature | Backend | Web app | This app before Epic 12 |
|---|---|---|---|
| Favorites | `isStarred` on files *and* folders; `PATCH /drive/files/{id}`, `PATCH /drive/folders/{id}`; `GET /drive?view=starred`; `GET /drive/starred?limit=` | Drive UI stars via PATCH, "Remove star"/"Star" in the context menu | `FavoritesView` renders the word "Favorites" |
| Pinning | **nothing** — no column, no endpoint | nothing | nothing |
| Recent Notes | `GET /drive?view=recent&limit=` — files only, `updated_at DESC`, trashed excluded | Drive's Recent view | `RecentsView` renders the word "Recents" |
| Trash | `GET /drive/trash`, restore, permanent delete, empty | yes | **done in Epic 4** |
| Tags | full CRUD: `/drive/tags`, `/drive/tags/{id}/files`, `GET/PUT /drive/files/{id}/tags`, `POST/DELETE /drive/files/{id}/tags/{tag_id}` | **no UI at all** — the API is unused by the web client | nothing |
| Nested folders | parent/child folders, bulk move | yes | **done in Epic 4** |

Two consequences worth stating up front.

### 1.1 Pinning has no server side, so it is device-local

There is no `is_pinned` column anywhere in `schema.rs` and no endpoint that could carry one. The
web app has no pin concept either, so "matches the web application" cannot mean a synced pin.
The honest options are (a) skip pinning, (b) invent a server feature (out of scope for an iOS
epic), or (c) implement it as a **device-local** preference.

This plan takes (c): pins live in `UserDefaults` under `nn.pinnedItemIDs` and float items to the
top of the current listing. It is genuinely useful on a phone, costs nothing, and is labelled as
on-this-device-only in the UI and the README so nobody expects it on the web. Favorites remain the
cross-device mechanism — that is what starring is for.

### 1.2 Tag names are plaintext on the server

`tags.name` is stored and indexed in the clear (`src/drive/tags/model.rs`), exactly like
`files.name`, which this app already sends in the clear as the multipart filename. So tagging
leaks no *new* class of data — note bodies stay end-to-end encrypted — but it does mean a tag is
metadata the server can read. Stated in the README next to the existing encryption notes rather
than buried.

Because the web client never built a tag UI, tags are additive rather than a compatibility
requirement: an iOS-created tag is visible to any future web UI through the same API.

### 1.3 Epic 11's request

`agent_docs/plans/feat-epic-11-search.md` §1.3 asked for Tags and Favorites to move out of Epic 11
into Epic 12, so that search inherits finished models rather than half-built read-only clients.
This plan delivers exactly that: `NoteItem.isStarred`, `NoteTag`, `TagsService`, and
`NotesDriveService.starredItems` are all available for Epic 11 to filter on.

## 2. Design decisions

### 2.1 One Drive client, not a FavoritesService

Starring is a Drive file/folder mutation on the same endpoint `rename` already PATCHes, and the
starred/recent listings are the same `GET /api/v1/drive` the browser already calls. Splitting them
into a second service would mean two clients holding two copies of the same `NoteItem`s that then
disagree after a mutation. So `NotesDriveService` gains `starredItems`, `recentItems`,
`setStarred`, `loadStarred`, and `loadRecents`, and every star mutation updates all three
collections optimistically, in the established fire-and-forget-with-rollback style.

Tags get their own `TagsService` — different resource, different endpoints, its own cache keyed by
tag and by file — mirroring how `VersionHistoryService` sits beside `NotesDriveService`.

### 2.2 The `view=recent` / `type=note` collision

`GET /api/v1/drive` accepts both `view` and `type`, but `get_root_contents` checks `type` **first**
and returns before it ever looks at `view` (`src/drive/filesystem/api.rs`). The two cannot be
combined: `?view=recent&type=note` is just `?type=note`, sorted by name, which is not "recent" at
all. So the recent and starred listings are fetched unfiltered and reduced client-side with the
existing `NoteItem.isVisibleInNotes` predicate — the same filter the folder listing already
applies. `limit=50` is requested for recents; the server's own default is 50 as well.

### 2.3 Starring bumps `updated_at`, which the offline sync layer reads as a conflict

`repository.rs::update_file` sets `updated_at = now` alongside `is_starred`. `SyncEngine` flags a
conflict when the server's `updatedAt` has moved past the timestamp a pending offline edit was
based on. So starring (or renaming — the same latent bug, present since Epic 9) a note that has an
unsynced offline edit would make the app announce a conflict that does not exist and ask the user
to choose between two versions of their own text.

Fix: `OfflineStore.rebasePendingEdit(id:previousModifiedAt:serverModifiedAt:)`. After a
metadata-only PATCH succeeds, the cached note's base timestamp moves to the value the server just
returned — but only if the cache has not already seen something newer than what we based the write
on, so a genuine remote content edit still conflicts. `NotesDriveService` gets a weak `offlineStore`
reference to call it, and both `setStarred` and `rename` use it.

### 2.4 No tag chips on list rows

There is no bulk "tags for these N files" endpoint — only `GET /drive/files/{id}/tags` — so showing
tags on every browser row would be one request per row. Tags therefore surface where a single
request is natural: the tag browser (`GET /drive/tags/{id}/files`, one request for a whole
listing), the editor's tag sheet, and the per-note picker. Rows show star and pin badges only.

### 2.5 Where each feature lives in the UI

Tabs stay as they are (Notes / Recents / Favorites / Offline / Settings) — Recents and Favorites
are exactly the placeholders this epic exists to fill. Tags need a home, and the Notes tab's
segmented section picker already is the "how do I look at my notes" control, so `NotesSection`
gains a `.tags` case: **My Notes | Tags | Trash**. Selecting it swaps the browser for the tag list;
tapping a tag pushes the notes carrying it; tapping a note pushes the editor already registered on
that stack. Switching sections now also resets the navigation path, so a folder pushed under My
Notes cannot linger under Trash.

## 3. Files

New:

- `Models/NoteTag.swift` — `id`/`name`/`createdAt`, `Codable`, sorted case-insensitively.
- `Services/TagsService.swift` — tag CRUD, per-file tag get/set, notes-for-tag, caches.
- `Services/PinStore.swift` — device-local pins in `UserDefaults` (injectable for tests).
- `Views/TagsView.swift` — tag list, create/rename/delete.
- `Views/TaggedNotesView.swift` — the notes carrying one tag.
- `Views/TagPickerSheet.swift` — assign/unassign/create tags for one note.

Rewritten: `Views/FavoritesView.swift`, `Views/RecentsView.swift`.

Modified:

- `Models/NoteItem.swift` — `isStarred` (defaulted, so no call site or fixture changes).
- `Models/NotesSection.swift` — `.tags`.
- `Services/NotesDriveService.swift` — star mutation, starred/recent listings, `isStarred`
  decoding, weak `offlineStore` for §2.3, `item(id:)` lookup across all three collections.
- `Services/OfflineStore.swift` — `rebasePendingEdit`.
- `Views/NoteRowView.swift` — star and pin badges.
- `Views/NoteBrowserView.swift` — pinned-first ordering, star/pin/tag actions.
- `Views/NotesView.swift` — `.tags` section, `NoteTag` destination, path reset.
- `Views/NoteEditorView.swift` — star, pin, and "Tags…" toolbar actions.
- `NeutrinoNotesApp.swift`, `ContentView.swift` — wire `TagsService` and `PinStore`.
- `Config/FeatureFlags.swift` — `organization`.
- `README.md`, `agent_docs/road_map.md`.

## 4. Tests

- `PinStoreTests` — pin/unpin/toggle round-trip through an injected `UserDefaults` suite,
  persistence across instances, pinned-first ordering that is stable for unpinned items, unknown
  ids inert.
- `NoteTagTests` — decoding a server payload (camelCase + Drive's zone-less timestamps), sorting.
- `TagsServiceTests` — cache updates via the DEBUG seed initializer, `tags(for:)` lookups,
  optimistic rename/delete against the caches.
- `NotesDriveServiceTests` (extended) — optimistic star/unstar across `allItems`/`starredItems`/
  `recentItems`, `item(id:)` lookup, `items(in: .tags)` empty.
- `OfflineStoreTests` (extended) — `rebasePendingEdit` moves the base timestamp, is skipped when
  the cache already knows something newer, is a no-op for unknown ids.
- `OrganizationViewTests` — hosting tests for `FavoritesView`, `RecentsView`, `TagsView`,
  `TaggedNotesView`, `TagPickerSheet`, in the `VersionHistoryViewTests` style (offline monitor, no
  token, so nothing reaches the network).
- `ContentViewTests` — updated wiring.

Manual verification: star a note on iOS and confirm the star in the web Drive UI (and back);
confirm a pinned note stays top of its folder and that the pin does *not* appear on another
device; confirm Recents reflects an edit made in the web app; create a tag, assign it to two notes,
filter by it, rename it, delete it; confirm starring a note with an unsynced offline edit does not
raise a conflict.
