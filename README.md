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

Note *content* is handled separately by `NoteContentService`, which mirrors the Drive app's upload/download encryption protocol exactly (XChaCha20-Poly1305 secretstream for the body, `crypto_box_seal` for the per-file key) so notes are readable by the web app and vice versa. `NoteEditorView` provides live Markdown editing over a plain `TextEditor`, debounced autosave via the Drive `PUT /files/{id}/autosave` endpoint, system undo/redo, word/character counts and estimated reading time (`NoteTextStats`), and find & replace via SwiftUI's `findNavigator`.
