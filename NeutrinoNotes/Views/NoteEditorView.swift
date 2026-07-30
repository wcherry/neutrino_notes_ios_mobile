import SwiftUI
import Sodium

// MARK: - NoteEditorView

/// Full-screen Markdown editor for a single note: live editing, autosave, undo/redo
/// (via the system UndoManager), word/character counts, reading time, and find & replace.
struct NoteEditorView: View {

    // MARK: - Parameters

    let item: NoteItem

    // MARK: - Environment

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var noteContentService: NoteContentService
    @EnvironmentObject var offlineStore: OfflineStore
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var versionHistoryService: VersionHistoryService
    @Environment(\.undoManager) private var undoManager

    // MARK: - State

    @State private var text: String = ""
    @State private var dek: Bytes?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isDirty = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var showFindNavigator = false
    // Epic 6 placeholder: a minimal Preview toggle so rendering can be seen at all.
    // Epic 7 will replace this with real Edit/Preview/Split View mode switching.
    @State private var isPreviewMode = false
    /// True when this session's text came from the offline cache rather than the server — either
    /// because the device is offline, or because the network load failed and a cached copy existed.
    /// Saves then go to the cache and are picked up by SyncEngine, so the edit is durable either way.
    @State private var usingOfflineCopy = false
    @State private var showVersionHistory = false
    @State private var showSaveVersionSheet = false

    private enum SaveStatus: Equatable {
        case idle
        case saving
        case saved
        case savedOffline
        case failed(String)
    }

    /// True when the offline-editing UI should engage for this session.
    private var isOfflineEditingActive: Bool {
        FeatureFlags.offlineEditing && !networkMonitor.isOnline
    }

    /// Version history is a server-side feature: snapshots aren't cached on the device, and
    /// saving one is a write. Both actions need the note's DEK, which only a loaded session has.
    private var isVersioningAvailable: Bool {
        FeatureFlags.versionHistory && dek != nil && networkMonitor.isOnline && !usingOfflineCopy
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                loadErrorView(loadError)
            } else {
                editorBody
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await load() }
        .onDisappear {
            pendingSaveTask?.cancel()
            if isDirty { Task { await save() } }
        }
        .sheet(isPresented: $showVersionHistory) {
            if let dek {
                VersionHistoryView(item: item, dek: dek, currentText: text) { modifiedAt, sizeBytes in
                    Task { await reloadAfterRestore(modifiedAt: modifiedAt, sizeBytes: sizeBytes) }
                }
            }
        }
        .sheet(isPresented: $showSaveVersionSheet) {
            SaveVersionSheet { label in
                Task { await saveVersion(label: label) }
            }
        }
    }

    // MARK: - Editor

    private var editorBody: some View {
        VStack(spacing: 0) {
            offlineBanner
            if isPreviewMode {
                MarkdownView(text: text)
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: text) { _ in scheduleAutosave() }
                    .findNavigator(isPresented: $showFindNavigator)
                    .replaceDisabled(false)
            }
            statusBar
        }
    }

    @ViewBuilder
    private var offlineBanner: some View {
        if isOfflineEditingActive {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                Text("You're offline. Edits will sync automatically once you're back online.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var statusBar: some View {
        let stats = NoteTextStats.compute(from: text)
        return HStack {
            Text("\(stats.wordCount) words · \(stats.characterCount) characters · \(stats.readingTimeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            saveStatusView
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var saveStatusView: some View {
        switch saveStatus {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Saving…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .saved:
            Text("Saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .savedOffline:
            Label("Saved offline · will sync", systemImage: "icloud.and.arrow.up.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Label("Save Failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showFindNavigator = true
            } label: {
                Label("Find & Replace", systemImage: "magnifyingglass")
            }
            // Find & Replace targets the TextEditor, which isn't shown in Preview mode.
            .disabled(isPreviewMode)

            Button {
                isPreviewMode.toggle()
            } label: {
                if isPreviewMode {
                    Label("Edit", systemImage: "eye.slash")
                } else {
                    Label("Preview", systemImage: "eye")
                }
            }
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                undoManager?.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoManager?.canUndo != true)

            Button {
                undoManager?.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(undoManager?.canRedo != true)

            if FeatureFlags.versionHistory {
                Button {
                    showSaveVersionSheet = true
                } label: {
                    Label("Save Version…", systemImage: "bookmark")
                }
                .disabled(!isVersioningAvailable)

                Button {
                    showVersionHistory = true
                } label: {
                    Label("Version History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!isVersioningAvailable)
            }
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil

        if isOfflineEditingActive {
            do {
                try loadFromCache()
            } catch OfflineStoreError.notCached {
                loadError = "Not available offline — download it while connected."
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
            return
        }

        do {
            let (loadedText, loadedDEK) = try await noteContentService.loadContent(for: item)
            text = loadedText
            dek = loadedDEK
            usingOfflineCopy = false
        } catch {
            // The network is nominally up but the fetch failed. If this note is downloaded, the
            // cached copy is a better answer than an error — fall back to it and keep the session
            // offline-first, so edits are persisted locally and synced by SyncEngine rather than
            // repeatedly failing against the same flaky connection.
            if FeatureFlags.offlineEditing, offlineStore.isAvailableOffline(item.id),
               (try? loadFromCache()) != nil {
                loadError = nil
            } else {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Reads this note's text and DEK out of the offline cache and marks the session offline-first.
    private func loadFromCache() throws {
        let (loadedText, loadedDEK) = try offlineStore.readPlaintext(id: item.id)
        text = loadedText
        dek = loadedDEK
        usingOfflineCopy = true
    }

    private func loadErrorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        isDirty = true
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard isDirty, let dek else { return }
        isDirty = false
        saveStatus = .saving

        if isOfflineEditingActive || (usingOfflineCopy && offlineStore.isAvailableOffline(item.id)) {
            guard offlineStore.isAvailableOffline(item.id) else {
                saveStatus = .failed("This note isn't downloaded, so offline edits can't be saved.")
                isDirty = true
                return
            }
            do {
                try offlineStore.writePendingEdit(text, id: item.id, dek: dek)
                saveStatus = .savedOffline
            } catch {
                saveStatus = .failed(error.localizedDescription)
                isDirty = true
            }
            return
        }

        do {
            let updatedAt = try await noteContentService.saveContent(text, for: item, dek: dek)
            notesDriveService.noteContentWasSaved(itemID: item.id, size: Int64(text.utf8.count), modifiedAt: updatedAt)
            if FeatureFlags.offlineEditing && offlineStore.isAvailableOffline(item.id) {
                refreshOfflineCache(savedAt: updatedAt, dek: dek)
            }
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
            isDirty = true
        }
    }

    // MARK: - Version History

    /// Saves the text currently on screen as a named snapshot. The server makes it the note's
    /// current content too, so this doubles as a save — the pending autosave is dropped rather
    /// than left to re-upload the identical bytes a moment later.
    private func saveVersion(label: String?) async {
        guard let dek else { return }
        pendingSaveTask?.cancel()
        saveStatus = .saving
        do {
            let version = try await versionHistoryService.saveVersion(text, for: item, dek: dek, label: label)
            isDirty = false
            // The snapshot's timestamp is the server's clock for this write; the device's is not.
            let savedAt = version.createdAt
            notesDriveService.noteContentWasSaved(itemID: item.id, size: Int64(text.utf8.count), modifiedAt: savedAt)
            if FeatureFlags.offlineEditing && offlineStore.isAvailableOffline(item.id) {
                refreshOfflineCache(savedAt: savedAt, dek: dek)
            }
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
        }
    }

    /// Pulls the restored content back into the editor. Any in-flight autosave is cancelled and
    /// the session marked clean first, so the pre-restore text can't be written back over the
    /// version the user just restored.
    private func reloadAfterRestore(modifiedAt: Date, sizeBytes: Int64) async {
        pendingSaveTask?.cancel()
        isDirty = false
        saveStatus = .idle
        await load()
        notesDriveService.noteContentWasSaved(itemID: item.id, size: sizeBytes, modifiedAt: modifiedAt)
        if FeatureFlags.offlineEditing, offlineStore.isAvailableOffline(item.id), let dek {
            refreshOfflineCache(savedAt: modifiedAt, dek: dek)
        }
    }

    /// After a successful online save, brings the offline cache up to the version just uploaded.
    /// Re-encrypts locally rather than re-downloading — the bytes are already in hand. Best-effort
    /// and non-fatal: the online save has already succeeded regardless of the outcome, and a stale
    /// cache entry is corrected by the next download or sync.
    private func refreshOfflineCache(savedAt: Date, dek: Bytes) {
        do {
            try offlineStore.cacheLocalVersion(text, id: item.id, dek: dek, serverModifiedAt: savedAt)
        } catch {
            // Intentionally ignored — see doc comment above.
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        NoteEditorView(item: NoteItem(
            id: "preview",
            name: "Meeting Notes.md",
            type: .file,
            parentID: nil,
            size: 1024,
            modifiedAt: Date(),
            isTrashed: false,
            mimeType: NoteItem.markdownMIME
        ))
        .environmentObject(NotesDriveService())
        .environmentObject(NoteContentService())
        .environmentObject(OfflineStore())
        .environmentObject(NetworkMonitor())
        .environmentObject(VersionHistoryService())
    }
}
