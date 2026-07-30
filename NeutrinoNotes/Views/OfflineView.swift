import SwiftUI

// MARK: - OfflineView

/// Sync status screen: pending queue count, last synced time, unresolved conflicts (tap to
/// resolve), and permanently-failed entries with a manual "Retry" action. A UI nicety per the
/// Epic 8 plan — kept simple, consistent with `NoteEditorView`'s empty/error-state visual
/// language (SF Symbols, `.secondary` text).
struct OfflineView: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var activeConflict: SyncConflict?

    var body: some View {
        List {
            Section {
                statusRow(systemImage: "tray.full", title: "Pending", value: "\(syncEngine.pendingCount)")
                statusRow(systemImage: "clock", title: "Last Synced", value: lastSyncedText)
                if syncEngine.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Syncing…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !syncEngine.conflicts.isEmpty {
                Section("Conflicts") {
                    ForEach(syncEngine.conflicts) { conflict in
                        Button {
                            activeConflict = conflict
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.itemName)
                                    .foregroundStyle(.primary)
                                Text("Changed on the server since your last edit")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !syncEngine.failedEntries.isEmpty {
                Section("Needs Attention") {
                    ForEach(syncEngine.failedEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(describe(entry.kind))
                                if let lastError = entry.lastError {
                                    Text(lastError)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Button("Retry") {
                                Task { await syncEngine.retryNow(entry) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if syncEngine.pendingCount == 0, syncEngine.conflicts.isEmpty, syncEngine.failedEntries.isEmpty {
                Section {
                    emptyStateView
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Offline")
        .refreshable { await syncEngine.runSync() }
        .sheet(item: $activeConflict) { conflict in
            ConflictResolutionView(conflict: conflict) { choice in
                Task {
                    _ = try? await syncEngine.resolve(conflict, choice: choice, localSource: .queuedCiphertext)
                    activeConflict = nil
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Everything is synced")
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow(systemImage: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func describe(_ kind: SyncOperationKind) -> String {
        switch kind {
        case .createFolder:           return "Create Folder"
        case .renameFolder:           return "Rename Folder"
        case .renameFile:             return "Rename Note"
        case .trashFile:              return "Move Note to Trash"
        case .trashFolder:            return "Move Folder to Trash"
        case .permanentDeleteFile:    return "Delete Note"
        case .permanentDeleteFolder:  return "Delete Folder"
        case .moveFile:               return "Move Note"
        case .moveFolder:             return "Move Folder"
        case .restoreFile:            return "Restore Note"
        case .restoreFolder:          return "Restore Folder"
        case .emptyTrash:             return "Empty Trash"
        case .saveNoteContent:        return "Save Note"
        }
    }

    private var lastSyncedText: String {
        guard let date = syncEngine.lastSyncedAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        OfflineView()
            .environmentObject(SyncEngine())
    }
}
