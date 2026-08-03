# Plan: Epic 11 — Search

Branch: `feat/epic-11-search` (from `main`, after Epic 10 merges)

## 1. Why the roadmap's Epic 11 is wrong

The roadmap says:

> Reuse existing search APIs where appropriate while maintaining a local index for offline content.
>
> Search: Title, Markdown body, Tags, Folder, Favorites

Three things in that are wrong, confirmed against the backend (`neutrino/src/drive/search/`,
`neutrino/src/notes/`) and the web client (`neutrino/web/packages/search/`).

### 1.1 There is a server search API, and we must not use it for note bodies

`GET /api/v1/drive/search` exists and is backed by a SQLite FTS5 table (`file_fts`). But that
table is only populated two ways:

| Source | What lands in the index |
|---|---|
| `SearchService::index_file_name` | The file's `name` — plaintext, already server-visible |
| `PUT /api/v1/jobs/files/{id}/content-index` | `{ "textContent": "..." }` — **note body plaintext** |

The content-index endpoint stores exactly what it is given into `file_content_index.text_content`
and the FTS table. It performs no encryption. **Any client that calls it to make body search work
has handed the server the plaintext of every note**, which is the one thing this app exists not to
do. `NoteContentService` encrypts every body with XChaCha20-Poly1305 before it leaves the device;
calling content-index would make that ceremony pointless.

So "reuse existing search APIs" is only safe for *titles*. `files.name` is already stored in the
clear server-side (`buildUploadBody` sends the name as the multipart filename, and every listing
response returns it), so title search leaks nothing new. Bodies cannot be server-searched, full
stop.

### 1.2 The web app does not use the server search API either

`neutrino/web/packages/search/` is a complete client-side search engine, and the web's search UI
(`apps/web/src/app/(apps)/search/page.tsx`, and the topbar in `(apps)/layout.tsx`) talks only to
it. It never calls `/api/v1/drive/search`, and it never calls content-index. Its design:

- A random 32-byte **search key** per user, generated locally, never sent to the server
  (`searchKey.ts`).
- Every term is HMAC-SHA256'd under that key before storage (`tokenizer.ts`) — a *blind index*.
  IndexedDB holds `{ tokenHash, documentId, field, frequency, positions }` and never the term.
- Query terms are hashed the same way and looked up; postings are intersected (AND), scored by
  frequency with a title weight of 3, capped at 20 results (`engine.ts`).

"Fully compatible with the web version" is a roadmap goal, so this is the behaviour to match. Note
that the index itself is per-device local state — IndexedDB on web, a file on iOS. There is nothing
to keep in sync between the two, and the search keys need not (and should not) match.

### 1.3 Tags and Favorites belong to Epic 12, not Epic 11

Epic 11 lists Tags and Favorites as search facets. Neither exists in this app yet — `FavoritesView`
is a placeholder that renders the word "Favorites", and there is no tag model, service, or UI at
all. Both are Epic 12 deliverables. The backend does have them (`GET /api/v1/drive/starred`,
`GET/PUT /api/v1/drive/files/{id}/tags`, with plaintext tag names), but building read-only tag and
star clients inside Epic 11 just to filter by them means Epic 12 inherits half-built plumbing it
then has to make writable.

**Recommendation: move Tags and Favorites out of Epic 11 and into Epic 12**, where they get their
models, services, and UI, and where adding them as search facets is a few lines against an index
that already exists.

### 1.4 What the roadmap gets right but understates

"Maintaining a local index for offline content" is right in spirit and much too narrow in scope.
The Epic 9 cache holds only notes the user explicitly tapped "Make Available Offline" on — usually
a handful. An index over just those would miss almost everything.

The unavoidable consequence of E2EE is: **to search bodies, this device must download and decrypt
every note at least once.** There is no way around it, and it is a materially bigger job than the
roadmap bullet implies. What we can control is what survives afterwards — we keep a derived index,
not the plaintext.

## 2. What this epic delivers

- **Title search** — instant, no corpus fetch, works from `GET /api/v1/notes` metadata alone.
- **Body search** — over a local, encrypted-at-rest inverted index built by fetching and decrypting
  the corpus once, then maintained incrementally.
- **Folder scoping** — filter results to a folder subtree, from `folderId` we already get for free.
- **Offline** — search works with no connection against whatever the index already holds.

Deferred to Epic 12: Tags, Favorites (see §1.3).

## 3. Design decisions

### 3.1 Index storage: encrypted inverted index, not a blind index

The web uses a blind index because IndexedDB is not encrypted at rest and is reachable by any
script on the origin. iOS has neither problem: the app sandbox plus Data Protection
(`.completeFileProtectionUnlessOpen`, already used by `OfflineStore`) gives real at-rest
encryption tied to the device passcode.

So rather than copying the blind index, we get a better result for the same guarantee: build a
**plain inverted index in memory, and persist it as a single ciphertext blob**, encrypted with the
same primitives `OfflineStore` uses — a random index key sealed to the Keychain key pair with
`crypto_box_seal`, body encrypted with XChaCha20-Poly1305 secretstream via
`NoteContentService.encrypt(text:dek:xcss:)`. Reading the index back requires the imported private
key, exactly like reading a cached note.

This preserves the invariant the README states for the offline cache — *nothing is ever written to
disk as plaintext* — while avoiding the blind index's real costs: it can do prefix matching
(HMACs can't, without indexing every prefix), real snippets, and better ranking.

Trade-off accepted: the whole index lives in memory while the app runs and is rewritten on flush.
Sizing says this is fine — `DriveClient::list_files` caps at 200 notes (§5.1), so worst case is a
few hundred KB. Flushes are debounced and forced on background, the same shape as editor autosave.

### 3.2 Corpus enumeration: `GET /api/v1/notes`, not a folder crawl

`NotesDriveService.allItems` is populated lazily, one folder per navigation, so the app never holds
the whole tree — you cannot search across notes the user has not browsed to.

`GET /api/v1/notes` returns every note file the user owns in one flat call: `id`, `title`,
`folderId`, `createdAt`, `updatedAt` (`src/notes/service.rs::list_notes`). The `notes` table is
keyed by `file_id` and filters on `application/x-neutrino-note`, so these are the same Drive files
`NotesDriveService` browses and the same ids `NoteContentService` fetches — no second corpus, no
crawl. This is the enumeration endpoint for both title search and index freshness.

### 3.3 Two tiers, so search is useful before the index is built

Title search needs only the `/api/v1/notes` response, so it works on first launch with zero
indexing. Body results appear for whatever has been indexed so far, with a visible "indexing 43 of
180" state rather than a silent partial answer. This avoids the web's failure mode, where search
returns nothing until you find the "Rebuild search index" button in Settings.

### 3.4 Index maintenance

The web only ever indexes via that manual Settings button — `indexDocument` is called from nowhere
else, so an edit made in the web app never updates its own index. We do not copy that.

- **Initial build** — user-initiated from the Search tab's empty state and from Settings, with
  progress, cancellable, and resumable (per-note, so a kill mid-build loses only the note in
  flight).
- **Incremental** — reindex a single note on every successful save: editor autosave
  (`NoteEditorView`), `SyncEngine` queue drain, and `NoteContentService.createNote`. This is one
  in-memory document update, effectively free.
- **Delta refresh** — on app foreground and pull-to-refresh, `GET /api/v1/notes` and diff
  `updatedAt` per id against the index: fetch only new and changed notes, drop ids that vanished.
  Cheap enough to run routinely.
- **Rename** — a rename changes `title` only, so it reindexes the title field without refetching
  the body.

### 3.5 Snippets

Result snippets need the matched note's text. Rather than a network round-trip per result, the
index stores a bounded per-note excerpt (first ~300 characters of normalized body) alongside token
positions, inside the encrypted blob. Enough for a useful preview, bounded so the index does not
become a de-facto full offline cache of every note — which would quietly undo Epic 9's deliberate
opt-in download model.

### 3.6 Query semantics — match the web

AND across terms, title weighted 3× body, ranked by weighted frequency, capped at 20. Two
deliberate additions over the web engine, both of which the blind index made impossible and the
encrypted index makes trivial:

- **Prefix matching on the last term**, so results narrow as you type rather than appearing only on
  whole words.
- **Diacritic-insensitive folding**, so `resume` matches `résumé`. The web normalizes to NFC and
  lowercases but keeps diacritics.

Tokenization otherwise mirrors `normalizeText`: NFC, lowercase, strip non-letter/non-digit, split
on whitespace.

### 3.7 No new dependencies

A pure-Swift index rather than SQLite FTS5 via `libsqlite3`. It keeps the index unit-testable
without a database the way `MarkdownParser` and `TextDiff` are, and encrypting one blob is simpler
than encrypting a live SQLite file. `project.yml` is unchanged.

## 4. Files

New:

- `Models/SearchIndex.swift` — the index itself: `[tokenHash: [Posting]]`, per-document entries
  (title tokens, body tokens, excerpt, `updatedAt`), `Codable`. Pure value type, no I/O, no crypto.
- `Models/SearchTokenizer.swift` — normalize/fold/split, mirroring the web's `normalizeText`.
- `Models/SearchResult.swift` — result row: note id, title, folder id, score, snippet range.
- `Services/SearchIndexStore.swift` — persistence. Owns `index.enc` in Application Support, the
  sealed index key, load/flush, debounce, and Data Protection attributes. Mirrors `OfflineStore`'s
  structure and delegates all crypto to `NoteContentService`.
- `Services/SearchService.swift` — `ObservableObject`. Owns corpus enumeration
  (`GET /api/v1/notes`), build/refresh/incremental-update, indexing progress, and `query(_:)`.
- `Views/SearchView.swift` — the search tab: search field, scope picker (All / this folder),
  results with title + folder + snippet + date, empty/indexing/no-results states.
- `Views/SearchResultRow.swift` — one result row with the snippet highlight.

Modified:

- `Views/ContentView.swift` — a Search tab. Five tabs are already at the limit that reads well;
  **Recents is the one to replace**, since it is still a placeholder stub and Epic 12 owns Recents
  anyway. Alternative is a search field in the Notes tab's navigation bar — worth a decision before
  I build it (§7).
- `Views/NoteEditorView.swift` — reindex on successful autosave.
- `Services/SyncEngine.swift` — reindex on successful queue drain.
- `Services/NoteContentService.swift` — reindex on `createNote`.
- `NeutrinoNotesApp.swift` — wire `SearchService`/`SearchIndexStore`, delta refresh on foreground.
- `Config/FeatureFlags.swift` — `search` flag, matching the epic-flag pattern.
- `Views/SettingsView.swift` — index status, "Rebuild index", "Clear index", size on disk.
- `README.md`, `agent_docs/road_map.md` — Epic 11 rewritten per §1, Tags/Favorites moved to
  Epic 12.

## 5. Backend facts worth knowing

### 5.1 The corpus is capped at 200 notes

`DriveClient::list_files` (`src/shared/drive_client.rs:83`) hardcodes `limit: 200, offset: 0`, so
`GET /api/v1/notes` silently returns at most 200 notes with no pagination and no total. A user with
more has a permanently incomplete index and no indication of it.

I will treat 200 as the working ceiling for this epic and surface it honestly in the index status
("200 notes indexed — this may not be all of them") rather than pretending completeness. The real
fix is backend pagination, which is out of scope here and worth raising separately.

### 5.2 To verify before building

- Whether `storage.list_files` filters trashed files, i.e. whether `GET /api/v1/notes` returns
  notes in Trash. If it does, they must be excluded from the index — a trashed note showing up in
  search is a bug. Check `FilesystemService::list_files`' `deleted_at` handling.
- Whether `GET /api/v1/notes` returns shared-with-me notes or only owned ones, which decides
  whether the DEK unseal can be assumed to succeed for every id in the list.

### 5.3 Observation, not scope

`SearchRepository` builds its FTS SQL by string interpolation, escaping only single quotes — the
`MATCH '{escaped_query}'` path takes user-controlled input (`src/drive/search/repository.rs:107`).
Since this plan deliberately avoids that endpoint it does not affect us, but it is worth a separate
look on the backend.

## 6. Tests

Unit, in the existing style — pure types tested directly, no network:

- `SearchTokenizerTests` — normalization, diacritic folding, punctuation, CJK/empty/whitespace-only
  input, and parity with the web's `normalizeText` on the cases in its `tokenizer.test.ts`.
- `SearchIndexTests` — add/update/remove a document; AND intersection; title weighting; prefix
  match on the last term; ranking order; result cap; stale postings removed on update (the bug
  `updateDocument`'s removal diff exists to prevent).
- `SearchIndexStoreTests` — round-trip through encryption with an injected temp directory and a
  stub `NoteContentService`, matching `OfflineStoreTests`' setup; corrupt/truncated/absent blob
  degrades to an empty index rather than crashing, as `OfflineStore.loadIndex` does; flush is
  atomic.
- `SearchServiceTests` — delta refresh picks exactly the changed/new/deleted ids from a stubbed
  `/api/v1/notes` payload; a note whose DEK fails to unseal is skipped without failing the build;
  cancel mid-build leaves a consistent partial index.

Manual verification: build the index against the live server, confirm a phrase in a note body found
only in a folder never browsed to, confirm results with the device in airplane mode, confirm an
edit made in the web app appears in iOS search after a foreground refresh.

## 7. Decisions I need from you

1. **Where search lives** — replace the placeholder Recents tab (my recommendation, since Epic 12
   owns Recents and would rebuild it anyway), or a search field in the Notes tab's nav bar with no
   new tab?
2. **Tags/Favorites moving to Epic 12** — confirming §1.3, since it edits the roadmap.
3. **First-run indexing** — prompt the user before the first full corpus download ("Index 180 notes
   for search? This downloads them once"), or build silently in the background on first launch
   after key import? Prompting is more honest about the data transfer; silent is less friction.
