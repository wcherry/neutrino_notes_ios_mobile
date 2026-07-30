# Neutrino Notes iOS

A secure, offline-capable Markdown editor for the Neutrino ecosystem. Built with SwiftUI, the app reuses Neutrino Drive as its storage layer and the existing Neutrino Auth and E2EE key services rather than inventing its own.

## Tech Stack

- Swift
- SwiftUI
- iOS 16+
- Xcode / XcodeGen

## MVP Epic Status

| Epic | Description | Status |
|------|-------------|--------|
| Epic 1 | Application Shell | COMPLETE |
| Epic 2 | Authentication | COMPLETE |
| Epic 3 | Key Import & Encryption | COMPLETE |
| Epic 4 | Drive Integration | COMPLETE |
| Epic 5 | Editor | COMPLETE |
| Epic 6 | Markdown Rendering | COMPLETE |
| Epic 9 | Offline Editing | COMPLETE |
| Epic 10 | Version History | COMPLETE |

See [agent_docs/road_map.md](agent_docs/road_map.md) for the full roadmap.

## Getting Started

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml`.

```sh
brew install xcodegen
xcodegen generate
open NeutrinoNotes.xcodeproj
```

## Architecture

The app is structured as a five-tab SwiftUI shell with tabs for Notes, Recents, Favorites, Offline, and Settings. Each tab keeps its own `NavigationStack` and navigation state; the Notes tab owns an explicit `NavigationPath` (in `NotesView`) so it can push straight into the editor after creating a note.

Authentication reuses Neutrino Drive's three-step OAuth PKCE flow (`AuthService`/`KeychainService`, ported from the Drive app) against the shared Neutrino Auth service: a session login, an in-app authorization step, and a token exchange, with access/refresh tokens persisted in the Keychain under `nn.*` keys distinct from Drive's `nd.*` keys. `NeutrinoNotesApp` gates `ContentView` behind `authService.isAuthenticated`, showing `LoginView` otherwise, and refreshes the token on launch if a session already exists. Encryption keys are imported and stored the same way as the Drive app (`KeyImportService`, `KeyQRDecryptService`), landing in the Keychain alongside the auth tokens.

The Notes tab is backed by `NotesDriveService`, which reuses Neutrino Drive's existing folder/file/trash REST APIs — there is no separate Notes backend. It filters every response down to folders and `text/markdown` files, and exposes optimistic `createFolder`/`rename`/`move`/`delete`/`restore` mutations (`NoteBrowserView`, `CreateFolderSheet`, `RenameSheet`, `MoveSheet`) so users can organize their notes exactly as they do on the web.

Offline support (`OfflineStore`, `SyncEngine`, `NetworkMonitor`) caches notes the user explicitly downloads via "Make Available Offline". The cache holds the server's ciphertext byte-for-byte and re-encrypts local edits with the same per-file DEK, so nothing is ever written to disk as plaintext and reading it back still requires the Keychain key pair. Edits made without a connection are written to a pending blob and queued; `SyncEngine` drains the queue on reconnect, on app foreground, and on demand, with exponential backoff. Before every upload it compares the server's current `updatedAt` against the version the edit was based on — if the server has moved ahead, the note is flagged as a conflict rather than uploaded, and the Offline tab lets the user keep either version. Note that this queue covers note *body* edits only, runs only while the app is alive, and does not use `BGTaskScheduler` — the broader mutation queue and background refresh remain Epic 8.

Note *content* is handled separately by `NoteContentService`, which mirrors the Drive app's upload/download encryption protocol exactly (XChaCha20-Poly1305 secretstream for the body, `crypto_box_seal` for the per-file key) so notes are readable by the web app and vice versa. `NoteEditorView` provides live Markdown editing over a plain `TextEditor`, debounced autosave via the Drive `PUT /files/{id}/autosave` endpoint, system undo/redo, word/character counts and estimated reading time (`NoteTextStats`), and find & replace via SwiftUI's `findNavigator`.

Markdown rendering (`NeutrinoNotes/Rendering/`) is layered on top of Apple's [`swift-markdown`](https://github.com/swiftlang/swift-markdown) package, which wraps `cmark-gfm` for CommonMark + GFM tables/strikethrough/task-lists. `MarkdownParser` walks the resulting AST into a pure-Swift, unit-testable model (`MarkdownModel.swift`) and layers a hand-rolled pre/post-processing pass on top for footnotes (`[^1]` refs and `[^1]: ...` definitions), which aren't part of GFM. `MarkdownInlineRenderer` turns inline runs into `AttributedString` (bold/italic/strikethrough/code/links/footnote markers), and `MarkdownView` walks the block model into native SwiftUI (headings, nested lists, read-only task-list checkboxes, `Grid`-based tables, code blocks, block quotes, thematic breaks, `AsyncImage`, tappable links, and a footnotes section). `NoteEditorView` exposes this behind a minimal Preview toggle in its toolbar that swaps the `TextEditor` for `MarkdownView`; this is intentionally a placeholder for Epic 7's Edit/Preview/Split View mode switching, not a finished UI.

Version history (`VersionHistoryService`, `VersionHistoryView`, `VersionCompareView`) reuses Drive's existing versioning endpoints — the app stores no revisions of its own. A snapshot is the ciphertext that was uploaded at the time and a file's DEK never rotates, so the DEK the editing session already holds decrypts every version of that note; all crypto is delegated to `NoteContentService`. Worth knowing: Drive's autosave endpoint deliberately does *not* snapshot, so history accumulates only from the initial upload (v1) and explicit saves — hence the editor's **Save Version…** action, matching the web app's explicit save. **Version History** lists previous versions, restores one (the server snapshots the current content first, so a restore is itself undoable), and compares any two sources — two snapshots, or a snapshot against the editor's current unsaved text — via a line-level diff (`TextDiff`). These actions need the server and the session key, so they're disabled offline. `DriveDate` is the shared timestamp parser the version endpoints forced: they return zoned RFC 3339 with a variable number of fractional digits, while the file endpoints return zone-less timestamps, and the two services that used to carry their own formatter lists now share it.
