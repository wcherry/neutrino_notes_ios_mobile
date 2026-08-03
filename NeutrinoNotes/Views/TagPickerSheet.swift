import SwiftUI

// MARK: - TagPickerSheet

/// Attaches and detaches tags on a single note, and creates new ones inline.
///
/// The selection is edited locally and written back on Save as the difference from what the note
/// already carried — one idempotent request per changed tag, rather than a replace-all `PUT`. A
/// tag attached elsewhere while this sheet was open therefore survives the save.
///
/// The search field filters the user's tags and doubles as the create field: typing a name that
/// matches nothing offers to create it, which is the only way to add a tag from here.
struct TagPickerSheet: View {

    // MARK: - Parameters

    let item: NoteItem

    // MARK: - Environment

    @EnvironmentObject var tagsService: TagsService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    form
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search or create a tag")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isLoading || isSaving)
                }
            }
            .task { await load() }
            .alert("Tags", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                if let name = createCandidate {
                    createRow(name: name)
                }
                if visibleTags.isEmpty && createCandidate == nil {
                    Text(tagsService.tags.isEmpty
                         ? "No tags yet — type a name in the search field to create one."
                         : "No tags match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleTags) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack {
                                Label(tag.name, systemImage: "tag")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedIDs.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(selectedIDs.contains(tag.id) ? [.isSelected] : [])
                    }
                }
            } header: {
                Text(item.name)
            } footer: {
                Text("Tag names are stored unencrypted, like note titles. Note contents stay encrypted.")
            }
        }
    }

    private func createRow(name: String) -> some View {
        Button {
            Task { await createTag(named: name) }
        } label: {
            HStack {
                Label("Create \u{201C}\(name)\u{201D}", systemImage: "plus.circle")
                Spacer()
                if isCreating { ProgressView() }
            }
        }
        .disabled(isCreating)
    }

    // MARK: - Filtering

    /// The tags the list shows for the current query. Filtering is client-side against the tag
    /// list the sheet already loaded, so typing costs no requests.
    private var visibleTags: [NoteTag] {
        Self.filter(tagsService.tags, matching: query)
    }

    /// The name the "Create" row offers, or nil when the query is blank or already names a tag.
    /// Matching is case-insensitive: the server rejects a duplicate regardless of case, so
    /// offering to create "work" beside an existing "Work" would only produce a 409.
    private var createCandidate: String? {
        Self.createCandidate(for: query, in: tagsService.tags)
    }

    /// Case- and diacritic-insensitive substring match on the tag name. Static and pure so the
    /// filtering rules are testable without hosting the view.
    static func filter(_ tags: [NoteTag], matching query: String) -> [NoteTag] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return tags }
        return tags.filter { $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func createCandidate(for query: String, in tags: [NoteTag]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let exists = tags.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        return exists ? nil : trimmed
    }

    // MARK: - Actions

    private func toggle(_ tag: NoteTag) {
        if selectedIDs.contains(tag.id) {
            selectedIDs.remove(tag.id)
        } else {
            selectedIDs.insert(tag.id)
        }
    }

    private func load() async {
        isLoading = true
        await tagsService.loadTags()
        do {
            let current = try await tagsService.loadTags(for: item.id)
            selectedIDs = Set(current.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Creates a tag and selects it straight away — creating one from here always means "and put
    /// it on this note". The query is cleared so the new tag is visible among the rest.
    private func createTag(named name: String) async {
        isCreating = true
        do {
            let tag = try await tagsService.createTag(named: name)
            selectedIDs.insert(tag.id)
            query = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    private func save() async {
        isSaving = true
        do {
            try await tagsService.applyTags(selectedIDs, to: item.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Preview

#Preview {
    TagPickerSheet(item: NoteItem(
        id: "preview",
        name: "Meeting Notes.md",
        type: .file,
        parentID: nil,
        size: 1024,
        modifiedAt: Date(),
        isTrashed: false,
        mimeType: NoteItem.markdownMIME
    ))
    .environmentObject(TagsService())
}
