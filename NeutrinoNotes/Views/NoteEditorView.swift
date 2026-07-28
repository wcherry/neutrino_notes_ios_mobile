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
    }

    // MARK: - Editor

    private var editorBody: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .onChange(of: text) { _ in scheduleAutosave() }
                .findNavigator(isPresented: $showFindNavigator)
                .replaceDisabled(false)
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
        isDirty = false
        saveStatus = .saving
        do {
            let updatedAt = try await noteContentService.saveContent(text, for: item, dek: dek)
            notesDriveService.noteContentWasSaved(itemID: item.id, size: Int64(text.utf8.count), modifiedAt: updatedAt)
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
            isDirty = true
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
    }
}
