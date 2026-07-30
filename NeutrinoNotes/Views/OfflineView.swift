import SwiftUI

// MARK: - OfflineView

/// Root view for the Offline tab: sync status, conflicts that need resolving, and the notes
/// currently cached on-device for offline access.
struct OfflineView: View {

    // MARK: - Environment

    @EnvironmentObject var offlineStore: OfflineStore
    @EnvironmentObject var syncEngine: SyncEngine
    @EnvironmentObject var networkMonitor: NetworkMonitor

    // MARK: - State

    @State private var actionError: String?

    // MARK: - Body

    var body: some View {
        Group {
            if FeatureFlags.offlineEditing {
                if offlineStore.notes.isEmpty {
                    emptyStateView
                } else {
                    list
                }
            } else {
                legacyPlaceholder
            }
        }
        .navigationTitle("Offline")
    }

    // MARK: - List

    private var list: some View {
        List {
            statusSection
            if offlineStore.conflictCount > 0 {
                conflictsSection
            }
            downloadedSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await syncEngine.syncNow()
        }
        .alert("Couldn't Complete Action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.body)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") {
                    syncEngine.requestSync()
                }
                .disabled(!networkMonitor.isOnline || isSyncing)
            }
            .padding(.vertical, 4)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = syncEngine.state { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch syncEngine.state {
        case .idle:
            Image(systemName: offlineStore.pendingCount > 0 ? "clock.arrow.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(offlineStore.pendingCount > 0 ? Color.secondary : Color.green)
                .font(.title3)
                .frame(width: 28)
        case .offline:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.title3)
                .frame(width: 28)
        case .syncing:
            ProgressView()
                .frame(width: 28)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)
                .frame(width: 28)
        }
    }

    private var statusTitle: String {
        switch syncEngine.state {
        case .idle:
            if offlineStore.pendingCount > 0 {
                return "\(offlineStore.pendingCount) Change\(offlineStore.pendingCount == 1 ? "" : "s") Pending"
            }
            return "Up to Date"
        case .offline:
            return "Offline"
        case .syncing(let remaining):
            return "Syncing \(remaining) Remaining"
        case .failed:
            return "Sync Failed"
        }
    }

    private var statusSubtitle: String {
        var parts: [String] = []
        if let lastSyncedAt = syncEngine.lastSyncedAt {
            parts.append("Last synced \(relativeDate(lastSyncedAt))")
        } else {
            parts.append("Never synced")
        }
        if case .failed(let message) = syncEngine.state {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Conflicts Section

    private var conflictsSection: some View {
        Section {
            Text("These notes changed on another device while you had unsynced offline edits. Choose which version to keep.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(conflictedNotes) { note in
                conflictRow(for: note)
            }
        } header: {
            Text("Conflicts")
        }
    }

    private var conflictedNotes: [OfflineNote] {
        offlineStore.notes.filter { $0.conflict != nil }
    }

    private func conflictRow(for note: OfflineNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.name)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button {
                    resolveKeepingLocal(note)
                } label: {
                    Label("Keep My Version", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await resolveKeepingServer(note) }
                } label: {
                    Label("Keep Server Version", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Downloaded Section

    private var downloadedSection: some View {
        Section {
            ForEach(offlineStore.notes) { note in
                NavigationLink {
                    NoteEditorView(item: note.asNoteItem)
                } label: {
                    downloadedRow(for: note)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        removeDownload(note)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Downloaded")
        }
    }

    private func downloadedRow(for note: OfflineNote) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name)
                    .font(.body)
                    .lineLimit(1)
                Text(downloadedSubtitle(for: note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if note.pendingEdit != nil {
                Label("Unsynced Changes", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func downloadedSubtitle(for note: OfflineNote) -> String {
        var parts = [formattedSize(note.sizeBytes), "Cached \(relativeDate(note.cachedAt))"]
        if note.pendingEdit != nil {
            parts.append("Unsynced changes")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        Section {
            HStack {
                Text("Storage Used")
                Spacer()
                Text(formattedTotalBytes)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedTotalBytes: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: offlineStore.totalBytesOnDisk)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        // A ScrollView (rather than a bare VStack) is required for .refreshable to attach —
        // pull-to-refresh should work even before anything has been downloaded.
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("No Notes Available Offline")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Use \"Make Available Offline\" from the Notes tab to download a note so you can read and edit it without a connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable {
            await syncEngine.syncNow()
        }
    }

    // MARK: - Legacy Placeholder

    private var legacyPlaceholder: some View {
        VStack {
            Spacer()
            Text("Offline")
                .font(.largeTitle)
            Spacer()
        }
    }

    // MARK: - Actions

    private func removeDownload(_ note: OfflineNote) {
        do {
            try offlineStore.remove(id: note.id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resolveKeepingLocal(_ note: OfflineNote) {
        do {
            try offlineStore.resolveKeepingLocal(id: note.id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resolveKeepingServer(_ note: OfflineNote) async {
        do {
            try await offlineStore.resolveKeepingServer(id: note.id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Formatting Helpers

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        OfflineView()
            .environmentObject(NotesDriveService())
            .environmentObject(NoteContentService())
            .environmentObject(NetworkMonitor())
            .environmentObject(OfflineStore())
            .environmentObject(SyncEngine(store: OfflineStore(), monitor: NetworkMonitor(), content: NoteContentService()))
            .environmentObject(VersionHistoryService())
    }
}
