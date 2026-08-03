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

    /// Set to true to enable the Phase 8 app lock feature (Face ID / Touch ID, with device
    /// passcode fallback, in front of the app's content). When false, the Settings section is
    /// hidden and neither the lock screen nor the app-switcher privacy shield is ever presented,
    /// regardless of what the user previously turned on.
    static let appLock: Bool = true
}
