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

    /// Set to true to enable the Epic 8 Sync Engine feature (durable retry queue, background
    /// sync, conflict detection/resolution). When false, mutations still enqueue (nothing is
    /// silently lost) but the queue only drains via the existing immediate-attempt path — no
    /// periodic foreground sweep, no background task submission, and no conflict-resolution UI.
    static let syncEngine: Bool = true
}
