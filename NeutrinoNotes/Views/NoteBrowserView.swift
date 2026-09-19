import SwiftUI

// MARK: - NoteBrowserView

/// Displays the contents of a Notes section, supporting folder navigation,
/// swipe actions, context menus, and sheet presentation for mutations.
struct NoteBrowserView: View {

    // MARK: - Parameters

    let section: NotesSection
    let parentID: String?
    /// Called after a new note is successfully created, so the caller can push straight into
    /// its editor. Defaults to a no-op for previews and callers that don't need it.
    var onNoteCreated: (NoteItem) -> Void = { _ in }

    // MARK: - Environment

    @EnvironmentObject var notesDriveService: NotesDriveService
    @EnvironmentObject var noteContentService: NoteContentService
    @EnvironmentObject var offlineStore: OfflineStore
    @EnvironmentObject var pinStore: PinStore

    // MARK: - State

    @State private var showCreateFolder = false
    @State private var showCreateNote = false
    @State private var showEmptyTrashConfirmation = false
    @State private var itemToRename: NoteItem?
    @State private var itemToMove: NoteItem?
    @State private var createNoteError: String?
    /// Epic 9: the item currently being downloaded for offline access, so its row can show a
    /// progress indicator instead of the static "available offline" badge.
    @State private var downloadingItemID: String?
    @State private var offlineActionError: String?
    /// Epic 12: the note whose tags are being edited.
    @State private var itemToTag: NoteItem?
    /// Epic 22: the item whose sharing is being managed.
    @State private var itemToShare: NoteItem?

    // MARK: - Computed

    /// Pinned items float to the top of My Notes and Shared — a pin is device-local, so it works
    /// just as well on somebody else's note. Trash keeps the server's ordering: a pin is about
    /// finding things you are working on, and nothing in the Trash qualifies.
    private var currentItems: [NoteItem] {
        let items = notesDriveService.items(in: section, parentID: parentID)
        guard FeatureFlags.organization, section == .myNotes || section == .shared else { return items }
        return pinStore.sorted(items)
    }

    private var navigationTitle: String {
        if let parentID {
            return notesDriveService.allItems.first(where: { $0.id == parentID })?.name ?? section.rawValue
        }
        return section.rawValue
    }

    // MARK: - Body

    var body: some View {
        Group {
            if notesDriveService.isLoading && currentItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentItems.isEmpty {
                emptyStateView
            } else {
                noteList
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .task(id: "\(section.rawValue)-\(parentID ?? "root")") {
            await notesDriveService.loadSection(section, parentID: parentID)
        }
        .alert("Error", isPresented: Binding(
            get: { notesDriveService.error != nil },
            set: { if !$0 { notesDriveService.error = nil } }
        )) {
            Button("OK") { notesDriveService.error = nil }
        } message: {
            Text(notesDriveService.error ?? "")
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(isPresented: $showCreateFolder, parentID: parentID) { folderName in
                notesDriveService.createFolder(name: folderName, parentID: parentID)
            }
        }
        .sheet(isPresented: $showCreateNote) {
            CreateNoteSheet(isPresented: $showCreateNote) { noteName in
                Task { await createNote(named: noteName) }
            }
        }
        .alert("Couldn't Create Note", isPresented: Binding(
            get: { createNoteError != nil },
            set: { if !$0 { createNoteError = nil } }
        )) {
            Button("OK") { createNoteError = nil }
        } message: {
            Text(createNoteError ?? "")
        }
        .sheet(item: $itemToRename) { item in
            RenameSheet(item: item) { newName in
                notesDriveService.rename(itemID: item.id, to: newName)
            }
        }
        .sheet(item: $itemToMove) { item in
            MoveSheet(item: item) { newParentID in
                notesDriveService.move(itemID: item.id, to: newParentID)
            }
            .environmentObject(notesDriveService)
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                notesDriveService.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all items in the Trash. This action cannot be undone.")
        }
        .alert("Offline Download", isPresented: Binding(
            get: { offlineActionError != nil },
            set: { if !$0 { offlineActionError = nil } }
        )) {
            Button("OK") { offlineActionError = nil }
        } message: {
            Text(offlineActionError ?? "")
        }
        .sheet(item: $itemToTag) { item in
            TagPickerSheet(item: item)
        }
        .sheet(item: $itemToShare) { item in
            ShareSheet(item: item)
        }
    }

    // MARK: - Note List

    private var noteList: some View {
        List {
            ForEach(currentItems) { item in
                noteRow(for: item)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await notesDriveService.loadSection(section, parentID: parentID)
        }
    }

    @ViewBuilder
    private func noteRow(for item: NoteItem) -> some View {
        Group {
            if isOpenable(item) {
                NavigationLink(value: item) {
                    rowContent(for: item)
                }
            } else {
                rowContent(for: item)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingSwipeActions(for: item)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            leadingSwipeActions(for: item)
        }
        .contextMenu {
            contextMenuItems(for: item)
        }
    }

    private func rowContent(for item: NoteItem) -> some View {
        NoteRowView(item: item,
                    offlineBadge: offlineBadge(for: item),
                    isPinned: FeatureFlags.organization && pinStore.isPinned(item.id),
                    showsDisclosure: isOpenable(item))
    }

    /// Whether tapping the row leads anywhere.
    ///
    /// A folder shared *with* this account is the one row that doesn't: Drive's folder listings
    /// filter on the caller's own user id, so `GET /drive/folders/{id}` 404s for a recipient and
    /// there is nothing to push. The notes inside a shared folder are shared individually (see
    /// `SharingService.share`), so they appear as rows of their own rather than being lost.
    private func isOpenable(_ item: NoteItem) -> Bool {
        if item.type == .folder { return !item.isShared }
        return FeatureFlags.markdownEditor
    }

    // MARK: - Swipe Actions

    @ViewBuilder
    private func trailingSwipeActions(for item: NoteItem) -> some View {
        switch section {
        case .myNotes:
            Button(role: .destructive) {
                notesDriveService.delete(itemID: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        // Nothing destructive belongs here: these items belong to somebody else, and every
        // mutating Drive endpoint except autosave is owner-scoped.
        case .shared, .tags:
            EmptyView()
        case .trash:
            Button(role: .destructive) {
                notesDriveService.delete(itemID: item.id)
            } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        }
    }

    @ViewBuilder
    private func leadingSwipeActions(for item: NoteItem) -> some View {
        switch section {
        case .myNotes:
            Button {
                itemToRename = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
            starSwipeAction(for: item)
            offlineSwipeAction(for: item)
        case .shared:
            // Downloading is the one thing a recipient can do to somebody else's note without
            // permission from Drive — it is a read.
            offlineSwipeAction(for: item)
        case .tags:
            EmptyView()
        case .trash:
            Button {
                notesDriveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
    }

    @ViewBuilder
    private func starSwipeAction(for item: NoteItem) -> some View {
        if FeatureFlags.organization {
            Button {
                notesDriveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
            } label: {
                Label(item.isStarred ? "Unstar" : "Favorite",
                      systemImage: item.isStarred ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
    }

    @ViewBuilder
    private func offlineSwipeAction(for item: NoteItem) -> some View {
        if FeatureFlags.offlineEditing && item.type == .file {
            if offlineStore.isAvailableOffline(item.id) {
                Button(role: .destructive) {
                    removeOfflineDownload(item)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    Task { await downloadOffline(item) }
                } label: {
                    Label("Make Available Offline", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
                .disabled(downloadingItemID == item.id)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for item: NoteItem) -> some View {
        switch section {
        case .myNotes:
            Button {
                itemToRename = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                itemToMove = item
            } label: {
                Label("Move", systemImage: "folder")
            }
            organizationContextMenuItems(for: item)
            shareContextMenuItem(for: item)
            offlineContextMenuItems(for: item)
            Divider()
            Button(role: .destructive) {
                notesDriveService.delete(itemID: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .shared:
            // Pinning is device-local, so it works on somebody else's note; everything else in the
            // organization menu is an owner-scoped write.
            if FeatureFlags.organization {
                Button {
                    pinStore.togglePin(item.id)
                } label: {
                    Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin to Top",
                          systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
                }
            }
            offlineContextMenuItems(for: item)
        case .tags:
            EmptyView()
        case .trash:
            Button {
                notesDriveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                notesDriveService.delete(itemID: item.id)
            } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        }
    }

    /// Epic 12: favorite (server-side, shared with the web app), pin (this device only), and tags
    /// (files only — folders can't be tagged).
    @ViewBuilder
    private func organizationContextMenuItems(for item: NoteItem) -> some View {
        if FeatureFlags.organization {
            Button {
                notesDriveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
            } label: {
                Label(item.isStarred ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: item.isStarred ? "star.slash" : "star")
            }
            Button {
                pinStore.togglePin(item.id)
            } label: {
                Label(pinStore.isPinned(item.id) ? "Unpin" : "Pin to Top",
                      systemImage: pinStore.isPinned(item.id) ? "pin.slash" : "pin")
            }
            if item.type == .file {
                Button {
                    itemToTag = item
                } label: {
                    Label("Tags\u{2026}", systemImage: "tag")
                }
            }
        }
    }

    /// Epic 22: sharing is owner-only server-side, so the action is offered only for items this
    /// account owns — which is everything reachable from My Notes, since Drive's listings are
    /// owner-scoped.
    @ViewBuilder
    private func shareContextMenuItem(for item: NoteItem) -> some View {
        if FeatureFlags.sharing && !item.isShared {
            Button {
                itemToShare = item
            } label: {
                Label("Share\u{2026}", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }

    @ViewBuilder
    private func offlineContextMenuItems(for item: NoteItem) -> some View {
        if FeatureFlags.offlineEditing && item.type == .file {
            if offlineStore.isAvailableOffline(item.id) {
                Button(role: .destructive) {
                    removeOfflineDownload(item)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    Task { await downloadOffline(item) }
                } label: {
                    Label("Make Available Offline", systemImage: "arrow.down.circle")
                }
                .disabled(downloadingItemID == item.id)
            }
        }
    }

    // MARK: - Offline Actions

    /// Epic 9: badge shown on a row's `NoteRowView` reflecting download/cache state.
    /// Only Markdown files can be made available offline — folders are never cached.
    private func offlineBadge(for item: NoteItem) -> NoteRowView.OfflineBadge? {
        guard FeatureFlags.offlineEditing, item.type == .file else { return nil }
        if downloadingItemID == item.id { return .downloading }
        guard let note = offlineStore.note(id: item.id) else { return nil }
        return note.pendingEdit != nil ? .unsyncedChanges : .available
    }

    private func downloadOffline(_ item: NoteItem) async {
        downloadingItemID = item.id
        defer { downloadingItemID = nil }
        do {
            try await offlineStore.download(item)
        } catch {
            offlineActionError = error.localizedDescription
        }
    }

    private func removeOfflineDownload(_ item: NoteItem) {
        do {
            try offlineStore.remove(id: item.id)
        } catch {
            offlineActionError = error.localizedDescription
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if section == .myNotes {
            if FeatureFlags.markdownEditor {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateNote = true
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showCreateFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }

        if section == .trash {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEmptyTrashConfirmation = true
                } label: {
                    Text("Empty Trash")
                        .foregroundStyle(.red)
                }
                .disabled(currentItems.isEmpty)
            }
        }

        // Every section, unlike New Folder above. A bug gets reported from whichever screen is
        // misbehaving, and that is rarely the root of My Notes.
        ToolbarItem(placement: .secondaryAction) {
            ReportBugButton()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        // A ScrollView (rather than a bare VStack) is required for .refreshable to attach —
        // pull-to-refresh should work even when the current folder has nothing in it yet.
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text(emptyStateTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(emptyStateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable {
            await notesDriveService.loadSection(section, parentID: parentID)
        }
    }

    private var emptyStateIcon: String {
        switch section {
        case .myNotes: return "note.text"
        case .shared:  return "person.2"
        case .tags:    return "tag"
        case .trash:   return "trash"
        }
    }

    private var emptyStateTitle: String {
        switch section {
        case .myNotes: return "No Notes Here"
        case .shared:  return "Nothing Shared With You"
        case .tags:    return "No Tags Yet"
        case .trash:   return "Trash is Empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch section {
        case .myNotes: return "Tap the note button to create your first Markdown note."
        case .shared:  return "Notes and folders other people share with you appear here."
        // TagsView owns this section; the browser only ever sees it via an exhaustive switch.
        case .tags:    return "Tags group notes across folders."
        case .trash:   return "Deleted notes are moved here before being permanently removed."
        }
    }

    // MARK: - Note Creation

    private func createNote(named name: String) async {
        do {
            let item = try await noteContentService.createNote(name: name, parentID: parentID)
            notesDriveService.noteWasCreated(item)
            onNoteCreated(item)
        } catch {
            createNoteError = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        NoteBrowserView(section: .myNotes, parentID: nil)
            .environmentObject(NotesDriveService())
            .environmentObject(NoteContentService())
            .environmentObject(OfflineStore())
            .environmentObject(VersionHistoryService())
            .environmentObject(TagsService())
            .environmentObject(PinStore())
            .environmentObject(SharingService())
    }
}
