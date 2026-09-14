import SwiftUI
import Sodium
import NeutrinoCore
import NeutrinoAuth

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
    @EnvironmentObject var linksService: LinksService
    /// Only for the file-events socket, which has to put a fresh token in its query string because
    /// a WebSocket handshake cannot carry an Authorization header.
    @EnvironmentObject var authService: AuthService
    /// Pushes a note onto whichever navigation stack this editor was opened from — the editor
    /// cannot push one itself. See `NoteRouter`.
    @Environment(\.noteRouter) private var noteRouter
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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

    // MARK: - Epic 20 / 24 State

    /// Epic 24: the file-events relay for this note. Owned by the editor, so it lives and dies with
    /// the screen that cares about it.
    @StateObject private var fileEvents = FileEventsClient()
    /// Set when a peer reported a change that couldn't be applied because the user is mid-edit.
    /// Drives the banner offering to reload; never applied behind their back.
    @State private var hasUnappliedRemoteChange = false
    /// Epic 20: the notes this device can resolve a `[[title]]` against.
    @State private var wikiLinkIndex = WikiLinkIndex()
    /// A tapped `[[title]]` that matches nothing yet, awaiting a decision to create it.
    @State private var unresolvedLinkTitle: String?
    @State private var linkError: String?

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
        .task { await loadBacklinks() }
        .task { await refreshWikiLinkIndex() }
        .onDisappear {
            pendingSaveTask?.cancel()
            if isDirty { Task { await save() } }
            fileEvents.disconnect()
        }
        // iOS tears a WebSocket down in the background whatever this app thinks, and a socket that
        // has quietly died looks exactly like one with nothing to report. Closing it deliberately
        // and re-opening on return is the difference between "no news" and "no connection".
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:     fileEvents.resume()
            case .background: fileEvents.suspend()
            default:          break
            }
        }
        .alert("Create Note", isPresented: Binding(
            get: { unresolvedLinkTitle != nil },
            set: { if !$0 { unresolvedLinkTitle = nil } }
        )) {
            Button("Cancel", role: .cancel) { unresolvedLinkTitle = nil }
            Button("Create") {
                if let title = unresolvedLinkTitle {
                    unresolvedLinkTitle = nil
                    Task { await createLinkedNote(titled: title) }
                }
            }
        } message: {
            Text("\u{201C}\(unresolvedLinkTitle ?? "")\u{201D} doesn\u{2019}t exist yet. Create it?")
        }
        .alert("Couldn\u{2019}t Open Link", isPresented: Binding(
            get: { linkError != nil },
            set: { if !$0 { linkError = nil } }
        )) {
            Button("OK") { linkError = nil }
        } message: {
            Text(linkError ?? "")
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
            remoteChangeBanner
            tagBar
            if isPreviewMode {
                MarkdownView(
                    text: text,
                    wikiLinkIndex: wikiLinkIndex,
                    backlinks: linksService.backlinks(for: item.id),
                    onWikiLinkTap: { title in open(wikiLinkTitle: title) },
                    onLinkTap: { url in open(markdownLink: url) },
                    onBacklinkTap: { link in open(backlink: link) }
                )
            } else {
                MarkdownTextEditor(text: $text, isEditable: !isReadOnly, controller: editorController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        slashCommandMenu
                            // The overlay spans the whole editor to position the menu inside it,
                            // so it must never stand between a tap and the text.
                            .allowsHitTesting(editorController.slashCommand != nil)
                    }
                    .overlay(alignment: .topLeading) {
                        wikiLinkMenu
                            .allowsHitTesting(editorController.wikiLink != nil)
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

    /// The note picker a `[[` opens. Offers the notes this device knows about, and — when the
    /// query matches none of them and this session may write — creating one by that name.
    ///
    /// Creating from here is a deliberate departure from the web app, which renders an unmatched
    /// link as inert text. Linking to a note that doesn't exist yet is how wiki links are actually
    /// used, and a phone is the worst place to be sent hunting for a New Note button.
    @ViewBuilder
    private var wikiLinkMenu: some View {
        GeometryReader { proxy in
            if FeatureFlags.noteLinks, let link = editorController.wikiLink {
                let suggestions = wikiLinkIndex.suggestions(for: link.query)
                let createTitle = createTitle(for: link.query, suggestions: suggestions)
                let rows = WikiLinkMenu.rowCount(suggestions: suggestions, createTitle: createTitle)
                if rows > 0 {
                    WikiLinkMenu(
                        suggestions: suggestions,
                        createTitle: createTitle,
                        onSelect: { note in
                            editorController.completeWikiLink(with: WikiLink.displayTitle(for: note.name))
                        },
                        onCreate: { title in
                            editorController.completeWikiLink(with: title)
                            Task { await createLinkedNote(titled: title, openIt: false) }
                        }
                    )
                    .offset(wikiMenuOffset(caret: link.caretRect, rows: rows, in: proxy.size))
                }
            }
        }
    }

    /// The name to offer creating for a half-typed link, or nil when there is nothing to offer:
    /// an empty query, a query that already names a note exactly, or a session that can't write.
    private func createTitle(for query: String, suggestions: [NoteItem]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReadOnly, networkMonitor.isOnline else { return nil }
        guard wikiLinkIndex.item(for: trimmed) == nil else { return nil }
        return trimmed
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

    /// The same placement rule as `menuOffset`, for a menu of a different width and row count.
    private func wikiMenuOffset(caret: CGRect, rows: Int, in size: CGSize) -> CGSize {
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let height = WikiLinkMenu.height(forRowCount: rows)

        let x = min(max(caret.minX, margin), max(margin, size.width - WikiLinkMenu.width - margin))

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

    /// Epic 24: somebody else changed this note while there were unsaved edits on screen.
    ///
    /// The change is never applied behind the user's back — their text is the thing they are
    /// looking at, and replacing it mid-sentence to show somebody else's version is the one
    /// unforgivable behaviour for an editor. The banner hands them the choice instead.
    @ViewBuilder
    private var remoteChangeBanner: some View {
        if hasUnappliedRemoteChange {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("This note changed somewhere else.")
                Spacer(minLength: 8)
                Button("Reload") {
                    Task { await reloadFromRemote() }
                }
                .font(.caption.weight(.semibold))
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

    /// Epic 20: what links *to* this note. Read access is enough, so it works on a shared note;
    /// silent on failure, like the tag bar, because it decorates a screen someone came here to
    /// write on. Skipped offline — there is nothing cached to show and nothing to be gained from
    /// a request that will fail.
    private func loadBacklinks() async {
        guard FeatureFlags.noteLinks, networkMonitor.isOnline, !usingOfflineCopy else { return }
        _ = try? await linksService.loadBacklinks(for: item.id)
    }

    /// Epic 20: the titles this device can resolve, for deciding which `[[links]]` are live and for
    /// the `[[` picker.
    ///
    /// `GET /api/v1/drive?type=note` is a whole-drive note listing, so one request covers notes in
    /// every folder — plus what the session already holds for notes other people have shared.
    private func refreshWikiLinkIndex(force: Bool = false) async {
        guard FeatureFlags.noteLinks else { return }
        if networkMonitor.isOnline {
            await notesDriveService.loadNoteIndex(force: force)
        }
        wikiLinkIndex = WikiLinkIndex(items: notesDriveService.linkableNotes)
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
        // Only now is it known whether this session is reading the server or the cache, which is
        // what decides whether a relay socket makes any sense.
        startFileEvents()
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
            await publishSideEffects(of: text)
        } catch {
            saveStatus = .failed(error.localizedDescription)
            isDirty = true
        }
    }

    /// What follows a successful *online* save: update the link graph, and tell anyone else with
    /// this note open that it moved.
    ///
    /// Deliberately after `saveStatus = .saved` and deliberately unable to change it. The content
    /// is on the server by now; a links request that fails is a stale edge, not a lost note, and
    /// the next save re-sends the whole set. Skipped for a read-only session, which the server
    /// would refuse anyway, and for an offline save, whose content hasn't reached the server yet —
    /// `SyncEngine` sends the links when it uploads the queued edit.
    private func publishSideEffects(of savedText: String) async {
        if FeatureFlags.noteLinks, !isReadOnly {
            await linksService.updateLinksIgnoringFailure(fileID: item.id, in: savedText)
        }
        fileEvents.broadcastFileUpdate()
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
            // A named version writes the note's current content too, so it moves the note and the
            // link graph exactly as an autosave does.
            await publishSideEffects(of: text)
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

    // MARK: - Epic 20: Following Links

    /// Opens the note a tapped `[[title]]` names, or offers to create it.
    ///
    /// "Not in the index" is not the same as "doesn't exist": a note in a folder this session never
    /// listed is invisible here even though the server would resolve the link. Refreshing the index
    /// before giving up costs one listing and turns a wrong offer to create a duplicate into a
    /// working link.
    private func open(wikiLinkTitle title: String) {
        guard FeatureFlags.noteLinks else { return }
        if let note = wikiLinkIndex.item(for: title) {
            noteRouter.open(note)
            return
        }
        Task {
            // Forced: the index was refreshed when this note opened, so an unforced call would sit
            // inside its TTL and answer with the same miss — and then offer to create a note that
            // already exists in a folder this session hasn't listed.
            await refreshWikiLinkIndex(force: true)
            if let note = wikiLinkIndex.item(for: title) {
                noteRouter.open(note)
            } else if isReadOnly || !networkMonitor.isOnline {
                // Nothing to open and nothing this session may create.
                linkError = "\u{201C}\(title)\u{201D} isn\u{2019}t a note you can open from here."
            } else {
                unresolvedLinkTitle = title
            }
        }
    }

    /// Opens a tapped `[text](destination)` link: a note in this stack, another Neutrino file in
    /// the app that owns it, and anything else wherever iOS decides it belongs.
    ///
    /// A link to a sibling note (`[Help](Help.md)`) never reaches here — it is an internal
    /// reference, and `MarkdownInlineRenderer.linkURL(forDestination:)` renders it as the same
    /// `nn-wikilink://` link a `[[Help]]` produces, so it arrives at `open(wikiLinkTitle:)`.
    private func open(markdownLink url: URL) {
        guard let destination = NeutrinoAppLink.destination(from: url) else {
            openExternally(url)
            return
        }
        guard destination.kind == .note else {
            openExternally(url)
            return
        }
        Task {
            if let note = notesDriveService.item(id: destination.fileID) {
                noteRouter.open(note)
                return
            }
            do {
                noteRouter.open(try await notesDriveService.fetchItem(id: destination.fileID))
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    /// Hands a link to iOS, and says so when iOS declines it.
    ///
    /// Silence is the wrong answer to a tap: a link the system can do nothing with is
    /// indistinguishable, from the reader's side, from an app that dropped the tap on the floor.
    private func openExternally(_ url: URL) {
        openURL(url) { accepted in
            guard !accepted else { return }
            linkError = "\u{201C}\(url.absoluteString)\u{201D} can\u{2019}t be opened from Notes."
        }
    }

    /// Opens a backlink: a note in this app, anything else in the app that owns it.
    ///
    /// The link graph is drive-wide, so a note can be linked from a doc or a sheet. Handing those
    /// to `NeutrinoAppLink` is the same routing the Universal Links work already built — Neutrino
    /// Docs takes the link if it is installed, and the web app takes it otherwise.
    private func open(backlink link: FileLink) {
        if link.isNote {
            Task {
                if let note = notesDriveService.item(id: link.id) {
                    noteRouter.open(note)
                    return
                }
                do {
                    noteRouter.open(try await notesDriveService.fetchItem(id: link.id))
                } catch {
                    linkError = error.localizedDescription
                }
            }
            return
        }

        guard let kind = link.kind, let url = NeutrinoAppLink.url(kind: kind, fileID: link.id) else {
            linkError = "\u{201C}\(link.displayTitle)\u{201D} can\u{2019}t be opened from Notes."
            return
        }
        openExternally(url)
    }

    /// Creates the note a link points at and, unless the caller is mid-typing, opens it.
    ///
    /// The new note goes in the same folder as this one — a link written here almost always belongs
    /// with it, and the alternative (the drive root) scatters notes made this way. The name gets the
    /// same `.md` this app puts on every note it creates; the link graph sends both spellings, so
    /// the link resolves either way.
    private func createLinkedNote(titled title: String, openIt: Bool = true) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReadOnly, networkMonitor.isOnline else { return }

        let name = trimmed.lowercased().hasSuffix(WikiLink.markdownExtension)
            ? trimmed
            : trimmed + WikiLink.markdownExtension
        // A shared note's `parentID` names a folder in *somebody else's* drive, which this account
        // cannot write to — so a note linked from one is created at the root of this drive instead.
        let parentID = item.isShared ? nil : item.parentID
        do {
            let created = try await noteContentService.createNote(name: name, parentID: parentID)
            notesDriveService.noteWasCreated(created)
            await refreshWikiLinkIndex()
            // The link in this note now resolves even though its text never changed, so this is
            // the one call that has to go out whether or not the titles look the same as last time.
            if FeatureFlags.noteLinks {
                await linksService.updateLinksIgnoringFailure(fileID: item.id, in: text, force: true)
            }
            if openIt {
                noteRouter.open(created)
            }
        } catch {
            linkError = error.localizedDescription
        }
    }

    // MARK: - Epic 24: Live File Events

    /// Opens the relay for this note, and says what to do when a peer rings the doorbell.
    ///
    /// Only ever for a note being read from the server: an offline session has no socket and
    /// nothing to reconcile with.
    private func startFileEvents() {
        guard FeatureFlags.liveFileEvents, networkMonitor.isOnline, !usingOfflineCopy else { return }
        fileEvents.authService = authService
        fileEvents.onRemoteUpdate = { handleRemoteUpdate() }
        fileEvents.connect(to: item.id)
    }

    /// A peer changed this note.
    ///
    /// Reload only when there is nothing of the user's to lose — no unsaved text, no save in
    /// flight, and not mid-typing with an autosave pending. Otherwise raise the banner and let them
    /// decide; whoever saves last still wins, exactly as before, but nobody's sentence disappears
    /// as they write it.
    private func handleRemoteUpdate() {
        guard !isDirty, saveStatus != .saving else {
            hasUnappliedRemoteChange = true
            return
        }
        Task { await reloadFromRemote() }
    }

    /// Re-reads and decrypts the note from the server. The relay carries no content, so this is
    /// where the change actually arrives.
    private func reloadFromRemote() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        isDirty = false
        hasUnappliedRemoteChange = false
        await load()
        await loadBacklinks()
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
        .environmentObject(LinksService())
        .environmentObject(AuthService())
    }
}
