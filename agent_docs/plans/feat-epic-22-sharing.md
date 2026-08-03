# Plan: Epic 22 — Sharing & Permissions

Branch: `feat/epic-22-sharing`

## 1. What the roadmap asks for, and what actually exists

> Phase 7 — Collaboration. Reuse existing Neutrino sharing infrastructure.
> Epic 22: Share notes, Shared folders, Permissions.

Checked against the backend (`neutrino/src/drive/permissions/`, `.../sharing/`, `.../encryption/`,
`.../filesystem/api.rs`, `neutrino/src/auth/api.rs`) and the web client
(`neutrino/web/apps/web/src/app/(apps)/drive/ShareDialog.tsx`, `.../drive/shared/page.tsx`):

| Feature | Backend | Web app | This app before Epic 22 |
|---|---|---|---|
| Per-user sharing | `GET/POST /drive/{files,folders}/{id}/permissions`, `PATCH`/`DELETE .../{user_id}` | `ShareDialog` — add by email, change role, revoke | nothing |
| Roles | `owner` / `editor` / `commenter` / `viewer`, inherited down the folder tree (`get_effective_role`) | same four | nothing |
| Sharing an E2EE file's key | `POST /drive/files/{id}/key/share` with the DEK sealed to the recipient's public key | `shareE2EKey()` in `ShareDialog` | nothing |
| Finding a recipient | `GET /auth/users/lookup?email=`, `GET /auth/users/search?q=` | both | nothing |
| Recipient's public key | `GET /auth/users/{id}/public-key` | yes | fetched already, but only as a debug diagnostic |
| Shared with me | `GET /drive/shared-with-me` — files + folders, flat | `/drive/shared` page | nothing |
| Link sharing | `PUT/PATCH/DELETE /drive/{files,folders}/{id}/share-link`, public `GET /share/{token}` | yes | nothing — and deliberately still nothing, see §2.4 |
| Caller's role on a file | `GET /drive/files/{id}/info` → `yourRole` | used by the doc editors | nothing |

Five consequences shape the whole epic.

### 1.1 Granting a permission is not enough: the DEK has to be re-wrapped

Every note this app writes is sealed with a per-file DEK, and the DEK itself is sealed to the
author's Curve25519 public key (`crypto_box_seal`). A permission row grants *access to bytes*; it
does not make those bytes readable. Sharing a note therefore has two halves, and the second one is
the one that matters:

1. `POST /drive/files/{id}/permissions` — the recipient can now fetch the file.
2. Unseal the DEK locally, re-seal it to the recipient's public key, `POST /drive/files/{id}/key/share`
   — the recipient can now *read* the file.

The server never sees the DEK; the re-wrap happens on the device, exactly as the web dialog does it.
The consequence is that **a recipient who has not imported their encryption keys yet cannot be given
a readable note**: there is no public key to seal to. The web app swallows this
(`.catch(err => console.warn(...))`) and silently shares an undecryptable file. This app does not:
the person's row shows "No encryption key — can't read this note", and a **Send Key** action re-runs
just the re-wrap once they have imported one. That is the honest state of affairs and the only way
the user can fix it.

### 1.2 Only owners can see who a note is shared with

`PermissionsService::list_permissions` answers 403 to anyone whose effective role is not `owner`,
as do grant/update/revoke. So the share sheet is an owner-only screen. Ownership is decided
client-side without an extra request: **every Drive listing this app already calls is owner-scoped**
(`find_folder(id, user_id)`, `list_files_in_folder(user_id, …)`), so anything reached through My
Notes / Recents / Favorites / Tags is owned by the caller, and anything reached through
`shared-with-me` is not. `NoteItem.isShared` carries that distinction, set only by the shared
listing.

### 1.3 A shared *folder* cannot be browsed by the recipient

`GET /drive/folders/{id}` is owner-scoped at the repository level — `find_folder` filters on
`user_id`, so a recipient gets 404, and `list_files_in_folder` would filter the contents to the
caller's own files anyway. `shared-with-me` returns the shared folder as a row, but nothing can be
listed inside it. The web app has the same hole (its shared page pushes `/drive?folder=…`, which
comes back empty).

Rather than ship a folder row that opens an empty screen, "Shared folders" is delivered as
**expansion at share time**: granting someone access to a folder also grants the same role on every
note inside it, recursively, and re-wraps each note's DEK for them. Those notes then appear as
individual rows in the recipient's Shared tab, open, and decrypt. The folder-level grant is still
made — it is what gives inherited access to anything added later at the API level — and the folder
row itself is shown in the Shared tab as a non-navigable row with a "shared folder" badge, so the
recipient can see it exists without being invited to tap into a 404.

A note added to the folder *after* the share still needs its own key re-wrap (a key can only be
sealed on a device that can unseal it, so the server cannot do this). The share sheet therefore
keeps a **Re-share folder contents** action, which re-applies permissions and keys to everything
currently inside. This is stated in the sheet's footer rather than left as a surprise.

### 1.4 Conflict detection was silently disabled for exactly the files that need it

`NoteContentService.fetchServerModifiedAt` has had to look a file's current `updatedAt` up by
listing its parent folder, because Drive had no per-file metadata endpoint. For a note shared *with*
the user, that folder belongs to somebody else: the listing 404s, the function returns nil, and
`SyncEngine` reads nil as "no server version to compare against" and uploads unconditionally. The
one case where two people really can be editing the same note is the case where the conflict check
was doing nothing.

`GET /drive/files/{id}/info` (added to Drive for the doc editors) returns `updatedAt`, `deletedAt`
and the caller's `yourRole` for any file the caller can access, owned or shared. `fetchServerModifiedAt`
now uses it: one request instead of a whole folder listing, correct for shared notes, and a trashed
file still reads as gone (`deletedAt != nil` → nil). The same call answers "what may I do with this
note", which is what the editor needs in §2.3.

### 1.5 Tags and stars behave differently on someone else's note

Drive's tag service is permission-aware (`require_file_access` to read, `require_file_edit` to
write) and tags are per-user, so an editor can tag a note shared with them and sees only their own
tags on it. `PATCH /drive/files/{id}` (rename, star) is *not* — it is owner-scoped and fails for a
recipient. So on a shared note the editor keeps Tags (when the role allows editing) and loses
Favorites and Rename. Pinning is device-local and always available.

## 2. Design decisions

### 2.1 A SharingService beside NotesDriveService, and the shared listing inside it

Permissions and users are a different resource with different endpoints and their own cache, so they
get their own service — the same reasoning that put `TagsService` and `VersionHistoryService` beside
`NotesDriveService` in Epics 10 and 12. The *listing* of shared items is the opposite case: it is
`NoteItem`s, from a Drive listing endpoint, which the browser renders and the editor is pushed from,
so `sharedItems` lives in `NotesDriveService` next to `starredItems` and `recentItems` (Epic 12 §2.1).

All crypto stays in `NoteContentService`, which owns the Sodium instance and the Keychain key pair.
`SharingService` orchestrates HTTP and calls it for the two crypto steps (`sealedFileKey(for:)`,
`seal(_:toRecipientPublicKey:)`); it never touches key material itself.

### 2.2 Shared is a section of the Notes tab, not a sixth tab

Five tabs is already the practical limit on an iPhone, and "notes somebody shared with me" is a way
of looking at notes — which is what the Notes tab's segmented picker is for. `NotesSection` gains
`.shared`: **My Notes | Shared | Tags | Trash**. This is the same call Epic 12 made for Tags.

### 2.3 A shared note opens read-only unless the server says otherwise

The editor asks `GET /files/{id}/info` for `yourRole` when — and only when — the note came from the
shared listing; for an owned note the answer is already known and no request is made. Until the role
arrives the editor is read-only, so a viewer never gets to type into a note they cannot save. A
`commenter` is treated as a viewer: this app has no comment UI (that is Epic 23), and the autosave
endpoint rejects both. The banner names the state ("Shared with you · View only" / "· You can edit"),
and every action that would fail server-side is disabled rather than left to error.

The role is deliberately not cached on the device, which means a shared note opened *offline* is
read-only even for an editor — the banner says "View only while offline". Caching it would let an
editor keep working on a plane, but it would also let a revoked collaborator queue edits against a
stale "editor" that the server will reject on reconnect, leaving text stranded in the offline queue.
Read-only offline is the answer that cannot lose somebody's writing; a cached role is worth
revisiting alongside Epic 8's broader mutation queue.

### 2.4 No link sharing in this epic

Drive's share links work by handing `/share/{token}/download` the file's stored bytes. For a
Markdown note those bytes are ciphertext, and a link recipient — who may not even have an account —
has no key ref and no way to obtain one. The web share page does not decrypt either; it offers a
download of the encrypted blob. Shipping a "Copy link" button on an E2EE note would produce a link
that reliably delivers garbage, so it is deliberately omitted, and the share sheet's footer says why.
Person sharing re-wraps the DEK and actually works. If Drive ever gains password-derived link keys,
this is the place to add it.

### 2.5 Sharing is all-or-nothing per person, and best-effort per note

`share(item:with:role:)` grants the permission first and re-wraps the key second, because a failed
key share is recoverable (**Send Key**) while a failed grant means the person has no access at all.
A folder share loops over the folder's notes and keeps going past individual failures, reporting
"shared 12 of 14 notes" rather than aborting halfway and leaving the user unable to tell what
happened. Permission mutations are optimistic with rollback, matching every other mutation in the
app.

## 3. Files

New:

- `Models/SharePermission.swift` — `ShareRole` (owner/editor/commenter/viewer, `canEdit`, ordering)
  and `SharePermission`. Deliberately does not decode `createdAt`: `PermissionResponse` stringifies
  a `NaiveDateTime` with `to_string()`, producing `"2026-07-30 14:25:36"` — a space, not a `T` —
  which is not one of the shapes `DriveDate` parses and is not needed by the UI.
- `Models/DirectoryUser.swift` — id/email/name from `/auth/users/lookup` and `/auth/users/search`.
- `Models/NoteFileInfo.swift` — `GET /drive/files/{id}/info`, including `yourRole` and `deletedAt`.
- `Services/SharingService.swift` — permissions CRUD, user lookup/search, DEK re-wrap, folder
  expansion, per-recipient key status.
- `Views/ShareSheet.swift` — the owner-only sharing screen.

Modified:

- `Models/NoteItem.swift` — `isShared` (defaulted, so no existing call site changes).
- `Models/NotesSection.swift` — `.shared`.
- `Services/NotesDriveService.swift` — `sharedItems`, `loadSection(.shared)` against
  `/drive/shared-with-me`, `item(id:)` and the seed initializer extended.
- `Services/NoteContentService.swift` — `fileInfo(for:)`, `sealedFileKey(for:)`,
  `seal(_:toRecipientPublicKey:)`, and `fetchServerModifiedAt` re-pointed at `/info` (§1.4).
- `Views/NoteBrowserView.swift` — the `.shared` section, non-navigable shared folders, and a
  "Share…" action on owned items.
- `Views/NoteEditorView.swift` — role fetch, read-only mode, shared banner, Share action, and the
  star/tag rules from §1.5.
- `Views/NoteRowView.swift` — a shared badge, and disclosure suppressed for un-openable folders.
- `Views/NotesView.swift` — the `.shared` section and a wider picker.
- `NeutrinoNotesApp.swift`, `ContentView.swift` — wire `SharingService`.
- `Config/FeatureFlags.swift` — `sharing`.
- `README.md`, `agent_docs/road_map.md`.

## 4. Tests

- `SharePermissionTests` — role decoding (including an unknown role falling back to viewer),
  `canEdit`, owner-first ordering, display name falling back to the email.
- `NoteFileInfoTests` — decoding `/info` with and without `deletedAt`, and the role it carries.
- `SharingServiceTests` — seeded caches; optimistic revoke and role change with rollback when the
  unauthenticated request fails; `resourcePath` for files vs folders; `keyStatus` bookkeeping;
  `noteIDs(in:)` folder expansion against a seeded listing.
- `NotesDriveServiceTests` (extended) — the shared listing feeds `items(in: .shared)` and
  `item(id:)`, and shared items are marked `isShared`.
- `SharingViewTests` — hosting tests for `ShareSheet` (owned and shared items), the browser in the
  `.shared` section, and the editor on a shared note, in the `OrganizationViewTests` style: offline
  monitor, no token, so nothing reaches the network.

56 tests added; 373 pass.

Manual verification: share a note with a second account by email and confirm it appears under that
account's Shared section, opens, and decrypts; confirm a viewer's editor is read-only and an editor's
saves reach the owner; share a folder and confirm each note inside becomes visible to the recipient;
add a note to a shared folder and confirm **Re-share folder contents** picks it up; share with an
account that has no imported key and confirm the sheet says so and that **Send Key** fixes it after
the recipient imports one; revoke access and confirm the note disappears from the recipient's Shared
section.
