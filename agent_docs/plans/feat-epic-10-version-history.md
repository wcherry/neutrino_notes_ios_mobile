# Plan: Epic 10 — Version History

Branch: `feat/epic-10-version-history`

## 1. What's changing and why

The roadmap's Epic 10 is three bullets — Previous versions, Restore version, Compare
versions — with the instruction "Reuse existing Drive version APIs." Those APIs already
exist and are already used by the web app; nothing server-side changes.

Confirmed against the backend (`neutrino/src/drive/storage/api.rs`) and the web client
(`neutrino/web/packages/api-drive/src/client.ts`):

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/api/v1/drive/files/{id}/versions` | List versions (`{ versions: [...], total }`) |
| `GET`  | `/api/v1/drive/files/{id}/versions/{vid}/download` | Raw snapshot bytes |
| `POST` | `/api/v1/drive/files/{id}/versions` | Save a named version (multipart: `file`, `label`) |
| `POST` | `/api/v1/drive/files/{id}/versions/{vid}/restore` | Restore, returns file metadata |

Two facts drive the design:

- **Snapshots are ciphertext.** A version's stored bytes are whatever was uploaded at the
  time, i.e. the same XChaCha20-Poly1305 secretstream blob the file endpoint returns. The
  per-file DEK never rotates, so the session DEK the editor already holds decrypts every
  version of that note. No new crypto, no new key fetch.
- **Autosave does not snapshot.** `StorageService::autosave` overwrites content without
  creating a version record; only upload (v1) and `save_named_version` create versions. So
  a Notes user who only ever autosaves would see a one-entry history. The web app solves
  this with an explicit "save version" action (`driveCreateEncryptedVersion`), and this epic
  does the same — **Save Version…** is included, because Restore and Compare are inert
  without a way to produce versions from the phone.

## 2. Scope decisions

- Version history is reachable **only from the open editor**. That's where the session DEK
  lives, so no extra `/key` round-trip is needed, and it matches the web app, where the
  panel is an editor sidebar rather than a file-browser action.
- **Compare** is a line-level diff between any two sources — any two snapshots, or a
  snapshot and the editor's current (possibly unsaved) text. The web compares a version
  against current only; a two-sided picker is a small addition and reads better on a phone
  than a fixed base.
- Out of scope (exists server-side, not in the roadmap bullets): renaming a version's label
  after the fact (`PATCH .../versions/{vid}`) and deleting a version
  (`DELETE .../versions/{vid}`).
- Version history requires the network. It is disabled offline rather than half-working
  from the Epic 9 cache — snapshots are server-side objects and are not cached.

## 3. Files

New:

- `Models/NoteVersion.swift` — the version record, `Decodable` straight from the API shape,
  with its own date decoder. The versions endpoint serializes `createdAt` as a chrono
  `DateTime<Utc>` (RFC 3339, `Z` suffix, 0/3/6/9 fractional digits), which the existing
  `NotesDriveService`/`NoteContentService` decoders — built for naive `NaiveDateTime`
  strings — would reject. The new decoder accepts both shapes.
- `Models/TextDiff.swift` — pure-Swift line diff (common prefix/suffix trim + LCS), no UIKit,
  unit-tested independently of any view.
- `Services/MultipartFormBody.swift` — the multipart builder extracted out of
  `NoteContentService` so the versions upload can reuse it instead of duplicating it.
- `Services/VersionHistoryService.swift` — list / download+decrypt / save named version /
  restore. Delegates all crypto to `NoteContentService` exactly as `OfflineStore` does.
- `Views/VersionHistoryView.swift` — the sheet: list, restore, entry point to compare.
- `Views/VersionCompareView.swift` — two-source picker plus the rendered diff.
- `Views/SaveVersionSheet.swift` — optional-label prompt for a named snapshot.

Changed:

- `NoteContentService.swift` — `buildUploadBody` now delegates to `MultipartFormBody`
  (same bytes on the wire, ordering preserved).
- `NoteEditorView.swift` — "Version History" and "Save Version…" in the overflow menu;
  restore reloads the note and refreshes the offline cache when the note is downloaded.
- `NeutrinoNotesApp.swift` — construct and inject `VersionHistoryService`.
- `FeatureFlags.swift` — `versionHistory`.
- `README.md`, `agent_docs/road_map.md` — status.

## 4. Tests

- `TextDiffTests` — identical input, pure insert, pure delete, interleaved edits, empty
  sides, trailing-newline handling, and the oversized-input fallback path.
- `NoteVersionTests` — decoding all four chrono fractional-digit shapes plus the naive
  shape, `total`/ordering, and the display helpers.
- `MultipartFormBodyTests` — field ordering, boundary framing, and that binary file bytes
  survive verbatim.
- `VersionHistoryServiceTests` — a snapshot round-trip through the real libsodium
  primitives (encrypt as the versions endpoint would receive, decrypt as the download path
  would), so the "same DEK decrypts every version" assumption is enforced by a test.
