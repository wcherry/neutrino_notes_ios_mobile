After reviewing your Neutrino Drive iOS MVP, I think the Notes app should follow the same philosophy and architecture. Unlike a standalone notes app, Neutrino Notes is fundamentally a document editor for the Neutrino ecosystem. The app should not invent its own authentication, synchronization, encryption, or storage model—it should reuse the existing platform services.

The roadmap below assumes:

* Reuse the existing Neutrino Auth service.
* Reuse Neutrino Drive as the storage layer.
* Reuse the existing E2EE key model and key import process.
* Support Markdown as the native document format.
* Be fully compatible with the web version so users can seamlessly switch between devices.
* Follow the phased approach used by the Neutrino Drive iOS MVP. mvp.md

Vision

Phase 1 (MVP)

A secure, offline-capable Markdown editor for Neutrino Drive.

Users can:

* Login
* Import encryption keys
* Browse notes stored in Drive
* Create/edit Markdown notes
* Sync automatically
* Read and edit offline

⸻

Phase 2

Native iOS editing experience.

⸻

Phase 3

Deep Apple ecosystem integration.

⸻

Phase 4

Advanced Notes features equivalent to the web application.

⸻

Architecture

Existing Neutrino Services

Reuse:

* Authentication
* Drive APIs
* Encryption APIs
* Key management
* Version history
* Sharing
* Search APIs

The Notes app should not maintain a separate backend.

⸻

iOS Components

SwiftUI Application

Responsible for

* Authentication
* UI
* Markdown editor
* Navigation

⸻

Encryption Layer

Responsible for

* Local encryption
* Local decryption
* Key access
* Secure Keychain integration

⸻

Local Cache

Responsible for

* Notes
* Metadata
* Sync queue
* Offline edits

⸻

Sync Engine

Responsible for

* Downloading changes
* Uploading edits
* Conflict handling
* Background synchronization

⸻

Phase 1 — Core Platform

Goal: Deliver a secure shell that connects to the Neutrino ecosystem.

✅ Epic 1 — Application Shell

Features

* ✅ SwiftUI app
* ✅ Navigation
* ✅ Settings
* ✅ Recent Notes
* ✅ Offline Notes
* ✅ Favorites

Milestone

Application launches with navigation and empty states.

⸻

✅ Epic 2 — Authentication

Reuse the browser-based login flow from Neutrino Drive.

Features

* ✅ Login
* ✅ Refresh tokens
* ✅ Logout
* ✅ Session persistence

Milestone

Users remain authenticated after app restart.

⸻

✅ Epic 3 — Key Import & Encryption

Reuse the identical workflow from the Drive app.

Features

* ✅ Import JSON key file
* ✅ Validate key pair
* ✅ Store in Keychain
* ⬜ Secure Enclave integration where available
* ✅ Delete temporary import file

Milestone

Device can encrypt and decrypt notes.

⸻

✅ Epic 4 — Drive Integration

The Notes app should browse only Markdown documents while using Drive as the storage backend.

Features

* ✅ Browse Notes folder
* ✅ Create folders
* ✅ Rename
* ✅ Move
* ✅ Delete
* ✅ Restore from Trash

Milestone

Users can organize notes exactly as they do in the web application.

⸻

Phase 2 — Markdown Editing

Goal: Build a first-class Markdown editor.

✅ Epic 5 — Editor

Features

* ✅ Live Markdown editing
* ✅ Autosave
* ✅ Undo/Redo
* ✅ Word count
* ✅ Character count
* ✅ Reading time
* ✅ Find
* ✅ Replace

Milestone

A reliable editor that supports large Markdown documents.

⸻

✅ Epic 6 — Markdown Rendering

Support

* ✅ Headers
* ✅ Lists
* ✅ Checklists
* ✅ Tables
* ✅ Images
* ✅ Code blocks
* ✅ Quotes
* ✅ Links
* ✅ Horizontal rules
* ✅ Footnotes
* ✅ Task lists

Milestone

Rendering matches the web version.

⸻

⬜ Epic 7 — Split View

Modes

* ⬜ Edit
* ⬜ Preview
* ⬜ Split View (iPad)

Milestone

Users can switch seamlessly between writing and previewing.

⸻

Phase 3 — Synchronization

Goal: Make editing feel seamless across devices.

✅ Epic 8 — Sync Engine

Features

* ✅ Background uploads
* ✅ Background downloads
* ✅ Delta synchronization
* ✅ Retry queue
* ✅ Conflict detection

Milestone

Edits made on the phone appear on the web version automatically.

⸻

✅ Epic 9 — Offline Editing

Features

* ✅ Download notes
* ✅ Edit offline
* ✅ Queue changes
* ✅ Sync when online

Milestone

Offline editing behaves identically to the web app.

⸻

⬜ Epic 10 — Version History

Reuse existing Drive version APIs.

Features

* ⬜ Previous versions
* ⬜ Restore version
* ⬜ Compare versions

Milestone

Users can recover earlier revisions.

⸻

Phase 4 — Search & Organization

⬜ Epic 11 — Search

Reuse existing search APIs where appropriate while maintaining a local index for offline content.

Search

* ⬜ Title
* ⬜ Markdown body
* ⬜ Tags
* ⬜ Folder
* ⬜ Favorites

Milestone

Fast, offline-capable search.

⸻

⬜ Epic 12 — Organization

Features

* ⬜ Favorites
* ⬜ Pinning
* ⬜ Recent Notes
* ⬜ Trash
* ⬜ Tags
* ⬜ Nested folders

Milestone

Organization matches the web application.

⸻

Phase 5 — Native iOS Experience

⬜ Epic 13 — Share Sheet

Users can create notes directly from:

* ⬜ Safari
* ⬜ Photos
* ⬜ Files
* ⬜ Other apps

⸻

⬜ Epic 14 — Widgets

Widgets

* ⬜ Recent notes
* ⬜ Favorites
* ⬜ Daily note
* ⬜ Quick capture

⸻

⬜ Epic 15 — Spotlight

Index

* ⬜ Titles
* ⬜ Recent notes
* ⬜ Favorites

⸻

⬜ Epic 16 — Siri Shortcuts

Examples

* ⬜ Create note
* ⬜ Search notes
* ⬜ Open today’s note
* ⬜ Append to note

⸻

Phase 6 — Advanced Notes Features

⬜ Epic 17 — Attachments

Support

* ⬜ Images
* ⬜ PDFs
* ⬜ Audio
* ⬜ Video
* ⬜ Documents

Attachments are stored in Neutrino Drive with the note referencing them.

⸻

⬜ Epic 18 — Drawing

PencilKit integration.

Features

* ⬜ Embedded sketches
* ⬜ Handwritten notes
* ⬜ Annotation

⸻

⬜ Epic 19 — Tables

Rich table editing

* ⬜ Insert rows
* ⬜ Delete rows
* ⬜ Formatting
* ⬜ Alignment

⸻

⬜ Epic 20 — Internal Links

Support wiki-style links.

Examples

[[Meeting Notes]]
[[Project Plan]]
[[Architecture]]

⸻

⬜ Epic 21 — Templates

Examples

* ⬜ Meeting Notes
* ⬜ Daily Journal
* ⬜ Project Plan
* ⬜ Brainstorm
* ⬜ To-do List

⸻

Phase 7 — Collaboration

Reuse existing Neutrino sharing infrastructure.

⬜ Epic 22

* ⬜ Share notes
* ⬜ Shared folders
* ⬜ Permissions

⸻

⬜ Epic 23

* ⬜ Comments
* ⬜ Mentions
* ⬜ Activity history

⸻

⬜ Epic 24

Real-time collaboration

* ⬜ Live cursors
* ⬜ Live editing
* ⬜ Conflict resolution

⸻

Phase 8 — Polish

* ⬜ Face ID / Touch ID lock
* ⬜ Handoff
* ⬜ Universal Clipboard
* ⬜ Multi-window (iPad)
* ⬜ Drag & Drop
* ⬜ Stage Manager
* ⬜ Accessibility
* ⬜ Localization
* ⬜ Performance optimization

⸻

MVP Success Criteria

I would define the MVP as complete when a user can:

* ✅ Log in using the existing Neutrino authentication flow
* ✅ Import and securely store E2EE keys using the same process as Neutrino Drive
* ✅ Browse their Notes folder in Neutrino Drive
* ✅ Create, edit, rename, move, and delete Markdown notes
* ✅ Autosave changes locally and sync them back to Drive
* ✅ Encrypt all note content before upload and decrypt it locally after download
* ✅ Access and edit notes offline with automatic synchronization when connectivity returns
* ✅ Render Markdown consistently with the web application
* ✅ Search notes by title and content
* ✅ Access version history through the existing Drive APIs

This roadmap deliberately mirrors the Neutrino Drive iOS MVP by making the Neutrino platform (authentication, Drive, encryption, key management, and synchronization) the foundation, while keeping the Notes app focused on delivering a best-in-class Markdown editing experience that remains fully compatible with the web version. mvp.md
