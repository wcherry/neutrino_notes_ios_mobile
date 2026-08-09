enum FeatureFlags {
    /// Set to true to enable the QR code key import flow.
    static let qrKeyScan: Bool = true

    /// Set to true to enable the Epic 4 Drive Integration feature (browsing, organizing,
    /// and managing the Markdown notes stored in Neutrino Drive).
    /// When false, the Notes tab shows the legacy placeholder.
    static let driveIntegration: Bool = true

    /// Set to true to enable the Epic 5 Markdown Editor feature.
    /// When false, the "New Note" button is hidden and tapping a note does nothing.
    static let markdownEditor: Bool = true

    /// Set to true to enable the Epic 9 Offline Editing feature (downloading notes for offline
    /// access, editing without a connection, and syncing queued changes when connectivity returns).
    static let offlineEditing: Bool = true

    /// Set to true to enable the Epic 10 Version History feature (saving named versions,
    /// browsing previous versions, restoring one, and comparing two).
    /// When false, the editor's version actions are hidden.
    static let versionHistory: Bool = true

    /// Set to true to enable the Epic 12 Organization feature (favorites, device-local pinning,
    /// recent notes, and tags). When false, the Recents and Favorites tabs show their placeholders,
    /// the Tags section is hidden, and no star/pin/tag actions appear.
    static let organization: Bool = true

    /// Set to true to enable the Epic 22 Sharing feature (sharing a note or folder with another
    /// Neutrino account, managing their role, and the Shared section listing what others have
    /// shared with you). When false, the Shared section is hidden and no share actions appear.
    static let sharing: Bool = true

    /// Set to true to accept inbound `https://www.getneutrino.app/open/note/<id>` Universal Links,
    /// which is how Neutrino Drive hands a note to this app.
    ///
    /// When false the link is ignored and the app opens on its usual screen. Turning it off does
    /// not remove the `applinks:` entitlement — that is a bundle property, not a runtime one — so
    /// iOS still launches the app with the URL; `onOpenURL` simply drops it.
    static let appLinks: Bool = true

    /// Set to true to enable the Epic 20 Internal Links feature: `[[wiki links]]` are parsed,
    /// rendered as links, completed by a `[[` picker, sent to Drive's link graph after every save,
    /// and the "Linked from" section appears under a note in Preview.
    ///
    /// Turning it off leaves `[[…]]` as literal text and stops the app calling
    /// `PATCH /api/v1/links/{id}` — which is also the switch for the one disclosure this feature
    /// makes, since that request carries link titles taken from an end-to-end-encrypted body in
    /// the clear. See `agent_docs/plans/feature-note-links-and-collaboration.md` §3.2.
    static let noteLinks: Bool = true

    /// Set to true to keep an open note in step with edits made elsewhere, over Drive's file-events
    /// relay (`GET /api/v1/files/{id}/ws`). The relay carries a signal only — never content — and
    /// the note is re-read and decrypted locally when one arrives.
    ///
    /// When false no socket is opened and the editor behaves as it did before: a change made on
    /// another device shows up the next time the note is opened.
    static let liveFileEvents: Bool = true

    /// Set to true to enable the Phase 8 app lock feature (Face ID / Touch ID, with device
    /// passcode fallback, in front of the app's content). When false, the Settings section is
    /// hidden and neither the lock screen nor the app-switcher privacy shield is ever presented,
    /// regardless of what the user previously turned on.
    static let appLock: Bool = true
}
