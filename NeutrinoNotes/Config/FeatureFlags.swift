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
}
