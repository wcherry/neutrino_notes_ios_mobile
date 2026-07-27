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
| Epic 3 | Key Import & Encryption | Pending |
| Epic 4 | Drive Integration | Pending |

See [agent_docs/road_map.md](agent_docs/road_map.md) for the full roadmap.

## Getting Started

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml`.

```sh
brew install xcodegen
xcodegen generate
open NeutrinoNotes.xcodeproj
```

## Architecture

The app is structured as a five-tab SwiftUI shell with tabs for Notes, Recents, Favorites, Offline, and Settings. Each tab is wrapped in a `NavigationStack` at the root `ContentView` level, keeping navigation state independent per tab.

Authentication reuses Neutrino Drive's three-step OAuth PKCE flow (`AuthService`/`KeychainService`, ported from the Drive app) against the shared Neutrino Auth service: a session login, an in-app authorization step, and a token exchange, with access/refresh tokens persisted in the Keychain under `nn.*` keys distinct from Drive's `nd.*` keys. `NeutrinoNotesApp` gates `ContentView` behind `authService.isAuthenticated`, showing `LoginView` otherwise, and refreshes the token on launch if a session already exists. Future epics will layer in encryption key management (reusing Neutrino Drive's key import flow), Drive-backed note browsing, and a full Markdown editor.
