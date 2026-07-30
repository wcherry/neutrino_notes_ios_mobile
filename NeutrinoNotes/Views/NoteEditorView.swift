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
    @EnvironmentObject var syncEngine: SyncEngine
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - State

    @State private var text: String = ""
    @State private var dek: Bytes?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isDirty = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var showFindNavigator = false
    /// The item's `modifiedAt` as of when this editing session started (or last saved) — used
    /// to detect whether the server copy has advanced past what this device knows about.
    @State private var loadedModifiedAt: Date?
    @State private var activeConflict: SyncConflict?
    // Epic 6 placeholder: a minimal Preview toggle so rendering can be seen at all.
    // Epic 7 will replace this with real Edit/Preview/Split View mode switching.
    @State private var isPreviewMode = false

    private enum SaveStatus: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
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
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, isDirty {
                checkForConflictBeforeSaving()
            }
        }
        .sheet(item: $activeConflict) { conflict in
            ConflictResolutionView(conflict: conflict) { choice in
                Task { await resolveConflict(conflict, choice: choice) }
            }
        }
    }

    // MARK: - Editor

    private var editorBody: some View {
        VStack(spacing: 0) {
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
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let (loadedText, loadedDEK) = try await noteContentService.loadContent(for: item)
            text = loadedText
            dek = loadedDEK
            loadedModifiedAt = notesDriveService.allItems.first(where: { $0.id == item.id })?.modifiedAt ?? item.modifiedAt
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
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

        // Before autosaving, check whether the server copy has advanced past what this editing
        // session last knew about (kept fresh by SyncEngine's delta sync via notesDriveService)
        // — if so, block the save and surface a conflict instead of silently overwriting.
        if let current = notesDriveService.allItems.first(where: { $0.id == item.id }),
           let loadedModifiedAt, current.modifiedAt > loadedModifiedAt {
            raiseConflict(serverModifiedAt: current.modifiedAt)
            return
        }

        isDirty = false
        saveStatus = .saving
        do {
            let updatedAt = try await noteContentService.saveContent(text, for: item, dek: dek)
            notesDriveService.noteContentWasSaved(itemID: item.id, size: Int64(text.utf8.count), modifiedAt: updatedAt)
            loadedModifiedAt = updatedAt
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
            // No blind isDirty=true retry here anymore: a retryable failure is now durably
            // queued by NoteContentService.saveContent itself (SyncEngine drains it with
            // backoff); looping forever on a non-retryable failure would just be noise. See
            // the Epic 8 report for the full rationale.
        }
    }

    // MARK: - Conflicts

    /// Re-checks for a conflict when the app returns to the foreground while this editor is
    /// open and there's an unsaved edit — catches the case where the server changed while the
    /// app was backgrounded, before the next autosave debounce would otherwise fire.
    private func checkForConflictBeforeSaving() {
        guard let current = notesDriveService.allItems.first(where: { $0.id == item.id }),
              let loadedModifiedAt, current.modifiedAt > loadedModifiedAt else { return }
        raiseConflict(serverModifiedAt: current.modifiedAt)
    }

    private func raiseConflict(serverModifiedAt: Date) {
        syncEngine.reportConflict(
            itemID: item.id, itemName: item.name, parentID: item.parentID,
            serverModifiedAt: serverModifiedAt, localModifiedAt: loadedModifiedAt
        )
        activeConflict = syncEngine.conflicts.first(where: { $0.itemID == item.id })
    }

    private func resolveConflict(_ conflict: SyncConflict, choice: ConflictChoice) async {
        let localSource: ConflictLocalSource = dek.map { .editorText(text, dek: $0) } ?? .queuedCiphertext
        do {
            let outcome = try await syncEngine.resolve(conflict, choice: choice, localSource: localSource)
            if let updatedText = outcome.updatedLocalText {
                text = updatedText
                isDirty = false
            }
            loadedModifiedAt = notesDriveService.allItems.first(where: { $0.id == item.id })?.modifiedAt ?? loadedModifiedAt
            activeConflict = nil
        } catch {
            saveStatus = .failed(error.localizedDescription)
            activeConflict = nil
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
        .environmentObject(SyncEngine())
    }
}
