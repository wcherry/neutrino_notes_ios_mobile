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
}
