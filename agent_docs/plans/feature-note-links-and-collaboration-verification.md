# Verification: Note Links & Collaboration (Epic 20, Epic 24 partial)

Companion to [`feature-note-links-and-collaboration.md`](./feature-note-links-and-collaboration.md).
What the automated tests cover, what they cannot, and the manual passes that close the gap.

## Automated

`xcodebuild -project NeutrinoNotes.xcodeproj -scheme NeutrinoNotes \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test` — **606 tests, 0 failures.**

New suites:

| Suite | Covers |
|---|---|
| `WikiLinkTests` | Extraction (four cases ported verbatim from `web/packages/markdown`, which are themselves ports of the backend's), case-insensitive dedup, the both-spellings request payload, UTF-16 ranges past an emoji, the `[[` token's open/close/scope rules |
| `WikiLinkIndexTests` | `.md`-insensitive resolution both ways, folders and trashed notes excluded, duplicate titles resolving to the most recently edited, suggestion ranking and limits |
| `WikiLinkRenderingTests` | The parser splitting a paragraph around a link, links inside emphasis, links inside inline code and fenced blocks staying literal, brackets dropped on render, the `nn-wikilink://` round trip, resolved vs. broken styling |
| `LinksServiceTests` | Cache reads/eviction, `BacklinksResponse` decoding, `fileType` → app-kind mapping, `notAuthenticated` mapping, and that `updateLinksIgnoringFailure` reports nothing on failure |
| `FileEventsClientTests` | Varint round trip and truncated-input safety, frame encode/decode, awareness frames ignored, own-echo distinguishable, socket URL scheme upgrade, **token sent verbatim** |
| `SyncEngineLinksTests` | A queued offline edit publishing its links *after* it uploads, publishing nothing when the upload was refused as a conflict, and the queue still working with no link publisher attached |
| `NoteRouterTests` | Hold-until-consumed, no double push, routers independent per stack |

## Verified against a live server

Done during implementation, against a build of the current backend source pointed at a **copy** of
the dev database (`PORT=8098`, `DATABASE_URL=<copy>`), so nothing below touched real data:

- `GET /api/v1/drive/folders/{id}?type=note` — files filtered to notes exactly (a folder with 21
  files of mixed type answered 17 notes); subfolders returned **unfiltered** (a folder of 76 docs
  answered `files: 0, folders: 3`). The root form, `folders/{userId}`, answered 107 notes and 3
  folders.
- `PATCH /api/v1/links/{id}` with titles nothing matches → `{"backlinks":[]}`, no error.
- `PATCH` with a real title → the linking note appears in the *target's* `GET …/backlinks`, and the
  PATCH's own response is the *source's* backlinks (empty), as the contract says.
- Both spellings of one title (`Name`, `Name.md`) → the existing one resolves, the other is dropped.

**The dev server running on `:8080` is older than the backend it serves.** It was started at 09:25
and the listing redesign landed at 11:55, so it still answers 404 to `folders/{userId}` — which is
now how the app lists My Notes. Restart it before testing the app against it, or the Notes tab will
look broken for reasons that have nothing to do with this work.

## Manual passes

Needs a signed-in session with keys imported on two clients (phone + web, or two devices).

### 1. Links round-trip with the web app

1. On the phone, in a note, type `[[` — the picker appears listing recent notes.
2. Pick one. The text completes to `[[Its Title]]` with the caret after the brackets.
3. Wait for "Saved", then open the *target* note in the web app.
   **Expect:** the source note listed under "Linked from".
4. In the web app, add `[[Some Phone Note]]` to a note and save. Open that phone note, switch to
   Preview.
   **Expect:** the web note listed under "Linked from" — this is the case the `.md` handling exists
   for, and the one that silently fails if it regresses.

### 2. Following and creating

5. Tap a resolved link in Preview. **Expect:** that note pushes onto the current stack; Back returns.
6. Do it from the **Recents** tab as well. **Expect:** it pushes onto Recents, and the Notes tab's
   stack is untouched when you switch to it.
7. Type `[[Something That Doesn't Exist]]`, save, and tap it in Preview.
   **Expect:** "Create …?" → creating puts the new note in the same folder, opens it, and the link
   renders live when you go back.
8. Open a note that a *doc* links to (create the link in the web app).
   **Expect:** the backlink row shows a doc icon, and tapping it hands off to Neutrino Docs (or
   Safari when it isn't installed) rather than trying to render a doc as Markdown.

### 3. Live updates (Epic 24)

9. Open one note on the phone and the same note in the web app. Edit and save in the web app.
   **Expect:** within a second or so the phone's copy updates on its own — with no reload.
10. Now type on the phone (don't wait for the save) and save in the web app while typing.
    **Expect:** the phone shows "This note changed somewhere else." with a **Reload** button and
    **does not** replace what you are typing. Reload pulls the other version in.
11. Background the app for a minute, come back.
    **Expect:** updates start arriving again (the socket is closed on background and re-opened on
    return).

### 4. Offline

12. Download a note, go into Airplane Mode, add `[[Another Note]]`, let it save offline.
    **Expect:** "Saved offline · will sync", no backlinks section, no picker offering to create.
13. Come back online and let the queue drain.
    **Expect:** the edit uploads *and then* the link appears on the target note's backlinks in the
    web app. Not before — the graph must never describe content the server hasn't got.

### 5. Read-only and flags

14. Open a note someone shared as **viewer**. **Expect:** links render and can be followed; no `[[`
    picker; no "create"; no links request (nothing to see in the log).
15. Set `FeatureFlags.noteLinks = false` and run. **Expect:** `[[Title]]` renders as literal text,
    brackets and all; no picker; no "Linked from"; no `PATCH /api/v1/links`.
16. Set `FeatureFlags.liveFileEvents = false`. **Expect:** no socket opened, and the editor behaves
    exactly as it did before this epic.
