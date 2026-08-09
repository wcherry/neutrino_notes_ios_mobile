# Feature: Opening a note from a Universal Link

Neutrino Drive hands a note to this app with:

```
https://www.getneutrino.app/open/note/<file id>[?v=<content version>]
```

The same link opens the note in the web app when Notes is not installed, which is the whole reason
this is an `https` link rather than a `neutrinonotes://` scheme.

**Only the file id travels.** The note itself is fetched here, against this app's own session, so
the reader always sees the current version and permissions stay server-side. `v` is an advisory hint
and nothing branches on it.

## Pieces

- `Models/NeutrinoAppLink.swift` — the link vocabulary and the MIME → app routing table.
  **Duplicated verbatim** in `neutrino_drive_ios_mobile` and `neutrino_docs_ios_mobile`: it is a
  wire format between three separately shipped binaries, so an app built last month must still open
  a link minted today. `NeutrinoAppLinkTests` pins it in each repository.
- `Services/DeepLinkRouter.swift` — holds the destination until there is a session to open it with.
  Accepts `/open/note/*` only; a `/open/doc/…` link belongs to Neutrino Docs.
- `NotesDriveService.fetchItem(id:)` — `GET /api/v1/drive/files/{id}/metadata`. `item(id:)` only
  sees listings this session loaded, and a link routinely names a note in a folder nobody has
  opened, or one shared by another account. Refuses a file whose MIME is not a note: an
  `/open/note/…` link pointing at a spreadsheet is malformed, and rendering it anyway would show
  garbage instead of an error.
- `NotesView.openPendingLink()` — pushes the editor onto the current stack. It deliberately does not
  switch `selectedSection` first: that resets `path` on the next update and would pop the note
  straight back off.

## Why nothing clears `pending` but `consume()`

A link can arrive at a cold launch straight onto the login screen, or while the app-lock overlay is
up. The router remembers the destination and the view layer picks it up once the user is signed in,
so a link that arrives before sign-in survives the whole login round trip.

## Deployment

Nothing works until `apple-app-site-association` is served from `www.getneutrino.app` listing
`46KWJJ63FU.com.neutrino.notes` against `/open/note/*`. That document, and the manual verification
steps for the whole feature, live in `neutrino_drive_ios_mobile`:

- `deploy/apple-app-site-association`, `deploy/README.md`
- `agent_docs/plans/feature-universal-links.md`
- `agent_docs/plans/feature-universal-links-verification.md`

## Kill switch

`FeatureFlags.appLinks`. It stops the app acting on links, but does not remove the `applinks:`
entitlement — that is a bundle property, so iOS still launches the app with the URL and `onOpenURL`
drops it.
