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
    @EnvironmentObject var pinStore: PinStore
    @EnvironmentObject var tagsService: TagsService

    // MARK: - State

    @State private var text: String = ""
    @State private var dek: Bytes?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isDirty = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var pendingSaveTask: Task<Void, Never>?
    /// The editing surface's undo, redo, and find & replace, reached from the toolbar.
    @StateObject private var editorController = MarkdownTextEditorController()
    // Epic 6 placeholder: a minimal Preview toggle so rendering can be seen at all.
    // Epic 7 will replace this with real Edit/Preview/Split View mode switching.
    @State private var isPreviewMode = false
    /// True when this session's text came from the offline cache rather than the server — either
    /// because the device is offline, or because the network load failed and a cached copy existed.
    /// Saves then go to the cache and are picked up by SyncEngine, so the edit is durable either way.
    @State private var usingOfflineCopy = false
    @State private var showVersionHistory = false
    @State private var showSaveVersionSheet = false
    @State private var showTagPicker = false
    @State private var showShareSheet = false
    /// Epic 22: what this account may do with a note somebody else owns, as the server reports it.
    /// nil until `GET /files/{id}/info` answers — and until then the editor stays read-only, so a
    /// viewer never types into a note they cannot save.
    @State private var sharedRole: ShareRole?

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
    ///
    /// Shared notes are excluded: Drive's version endpoints resolve the file with
    /// `find_file(id, user_id)`, so they answer 404 to anyone but the owner however the note is
    /// shared. Hiding the actions is honest; enabling them would produce a "file not found" on tap.
    private var isVersioningAvailable: Bool {
        FeatureFlags.versionHistory && dek != nil && networkMonitor.isOnline
            && !usingOfflineCopy && !item.isShared
    }

    // MARK: - Epic 22: Role

    /// What this account may do with the note. An owned note needs no request to answer this —
    /// every Drive listing it could have been reached through is owner-scoped.
    private var effectiveRole: ShareRole {
        item.isShared ? (sharedRole ?? .viewer) : .owner
    }

    /// True when this session may not write. Drive's autosave endpoint requires `owner` or
    /// `editor`, so a viewer — or a commenter, who has no comment UI here until Epic 23 — gets a
    /// read-only editor rather than a save that fails a second after they stop typing.
    private var isReadOnly: Bool {
        !effectiveRole.canEdit
    }

    /// True when the note is somebody else's and the server hasn't said what may be done with it —
    /// either the answer is still in flight, or there is no connection to ask over. Read-only
    /// either way; the banner distinguishes them so an editor offline isn't left wondering.
    private var isRoleUnknown: Bool {
        item.isShared && sharedRole == nil
    }

    /// Sharing is owner-only server-side (Drive answers 403 to anyone else listing permissions),
    /// and every part of it is a network call.
    private var isShareActionAvailable: Bool {
        FeatureFlags.sharing && !item.isShared && networkMonitor.isOnline
    }

    /// The live star flag: the service's copy is the one the star action updates, and it may be
    /// newer than the `item` this view was pushed with.
    private var isStarred: Bool {
        notesDriveService.item(id: item.id)?.isStarred ?? item.isStarred
    }

    /// Favorites and tags are server writes, so they need a connection. Pinning is local and
    /// always available.
    private var areServerOrganizationActionsAvailable: Bool {
        FeatureFlags.organization && networkMonitor.isOnline
    }

    /// Starring is a `PATCH /files/{id}`, which Drive scopes to the file's owner, so Favorites is
    /// unavailable on a note shared with this account however generous the role.
    private var isFavoriteActionAvailable: Bool {
        areServerOrganizationActionsAvailable && !item.isShared
    }

    /// Tagging *is* permission-aware server-side (`require_file_edit`), and tags are per-user, so
    /// an editor may tag a note somebody shared with them and sees only their own tags on it.
    private var areTagActionsAvailable: Bool {
        areServerOrganizationActionsAvailable && effectiveRole.canEdit
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
        .task { await loadTags() }
        .task { await loadRole() }
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
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(item: item)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(item: item)
        }
    }

    // MARK: - Editor

    private var editorBody: some View {
        VStack(spacing: 0) {
            offlineBanner
            sharedBanner
            tagBar
            if isPreviewMode {
                MarkdownView(text: text)
            } else {
                MarkdownTextEditor(text: $text, isEditable: !isReadOnly, controller: editorController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        slashCommandMenu
                            // The overlay spans the whole editor to position the menu inside it,
                            // so it must never stand between a tap and the text.
                            .allowsHitTesting(editorController.slashCommand != nil)
                    }
                    .onChange(of: text) { _ in scheduleAutosave() }
            }
            statusBar
        }
    }

    /// The format menu a `/` opens, floating next to the caret that opened it. Absent while nothing
    /// has been typed that matches a format, so a note that happens to contain "/usr/local" doesn't
    /// get a menu in its face.
    @ViewBuilder
    private var slashCommandMenu: some View {
        GeometryReader { proxy in
            if let command = editorController.slashCommand {
                let formats = MarkdownFormat.matching(command.query)
                if !formats.isEmpty {
                    SlashCommandMenu(formats: formats) { format in
                        editorController.apply(format)
                    }
                    .offset(menuOffset(caret: command.caretRect, rows: formats.count, in: proxy.size))
                }
            }
        }
    }

    /// Puts the menu just under the caret, and out of its own way: shifted left to stay on screen,
    /// and flipped above the line when there isn't room below it.
    private func menuOffset(caret: CGRect, rows: Int, in size: CGSize) -> CGSize {
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let height = SlashCommandMenu.height(forRowCount: rows)

        let x = min(max(caret.minX, margin), max(margin, size.width - SlashCommandMenu.width - margin))

        var y = caret.maxY + gap
        if y + height > size.height - margin {
            y = caret.minY - height - gap
        }
        y = min(max(y, margin), max(margin, size.height - height - margin))

        return CGSize(width: x, height: y)
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

    /// Says whose note this is and what may be done with it. Shown for the whole session on a
    /// shared note, including while the role is still being fetched, so "view only" is never a
    /// surprise that arrives after the first keystroke.
    @ViewBuilder
    private var sharedBanner: some View {
        if FeatureFlags.sharing && item.isShared {
            HStack(spacing: 6) {
                Image(systemName: isReadOnly ? "eye" : "pencil")
                Text(sharedBannerText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    /// Whose note this is, and what may be done with it. Offline gets its own wording: this app
    /// deliberately does not cache a role, so an editor without a connection is held to read-only
    /// rather than allowed to queue an edit that might be rejected on reconnect.
    private var sharedBannerText: String {
        if isRoleUnknown && !networkMonitor.isOnline {
            return "Shared with you · View only while offline"
        }
        return isReadOnly ? "Shared with you · View only" : "Shared with you · You can edit"
    }

    /// The note's tags, shown only once there are some — the row costs no space on an untagged
    /// note, and is the only way to see a note's tags without opening the picker. Each chip opens
    /// the picker, which is where tags are actually changed.
    @ViewBuilder
    private var tagBar: some View {
        let tags = tagsService.tags(for: item.id)
        if FeatureFlags.organization && !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags) { tag in
                        Button {
                            showTagPicker = true
                        } label: {
                            Label(tag.name, systemImage: "tag")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!areTagActionsAvailable)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
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
                editorController.presentFindNavigator(showingReplace: !isReadOnly)
            } label: {
                Label("Find & Replace", systemImage: "magnifyingglass")
            }
            // Find & Replace targets the text editor, which isn't shown in Preview mode.
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
                editorController.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(editorController.undoManager?.canUndo != true)

            Button {
                editorController.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(editorController.undoManager?.canRedo != true)

            if FeatureFlags.sharing && !item.isShared {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share\u{2026}", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!isShareActionAvailable)
            }

            if FeatureFlags.organization {
                Button {
                    notesDriveService.setStarred(itemID: item.id, isStarred: !isStarred)
                } label: {
                    Label(isStarred ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: isStarred ? "star.slash" : "star")
                }
                .disabled(!isFavoriteActionAvailable)

                Button {
                    pinStore.togglePin(item.id)
                } label: {
                    Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin to Top",
                          systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
                }

                Button {
                    showTagPicker = true
                } label: {
                    Label("Tags\u{2026}", systemImage: "tag")
                }
                .disabled(!areTagActionsAvailable)
            }

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

    /// Fills the tag bar. Deliberately silent on failure: tags are decoration next to the note's
    /// text, and there is nothing useful to say to someone who came here to write.
    private func loadTags() async {
        guard FeatureFlags.organization, networkMonitor.isOnline else { return }
        _ = try? await tagsService.loadTags(for: item.id)
    }

    /// Asks the server what this account may do with a note somebody else owns.
    ///
    /// Only ever a request for a shared note: an owned one is owned by definition, and paying a
    /// round trip to be told so would slow down every note the user opens. A failure leaves the
    /// session read-only, which is the safe answer — an editor sees it flip to writable a moment
    /// later, a viewer never gets to type into something they cannot save.
    private func loadRole() async {
        guard FeatureFlags.sharing, item.isShared, networkMonitor.isOnline else { return }
        do {
            sharedRole = try await noteContentService.fileInfo(for: item.id)?.yourRole
        } catch {
            // Intentionally silent — see doc comment above.
        }
    }

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
        // Belt and braces: the editor is disabled when read-only, so this shouldn't fire, but a
        // programmatic change to `text` must not queue a write the server will reject.
        guard !isReadOnly else { return }
        isDirty = true
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard !isReadOnly, isDirty, let dek else { return }
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
        .environmentObject(TagsService())
        .environmentObject(PinStore())
            .environmentObject(SharingService())
    }
}
