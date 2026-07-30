import SwiftUI

// MARK: - TagPickerSheet

/// Attaches and detaches tags on a single note, and creates new ones inline.
///
/// The selection is edited locally and written back with one `PUT /files/{id}/tags` on Save — the
/// server replaces a file's tags wholesale, so any number of additions and removals costs a single
/// request.
struct TagPickerSheet: View {

    // MARK: - Parameters

    let item: NoteItem

    // MARK: - Environment

    @EnvironmentObject var tagsService: TagsService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedIDs: Set<String> = []
    @State private var newTagName = ""
    @State private var isLoading = true
    @State private var isSaving = false
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
                if tagsService.tags.isEmpty {
                    Text("No tags yet — create one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tagsService.tags) { tag in
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

            Section("New Tag") {
                HStack {
                    TextField("Tag name", text: $newTagName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await createTag() } }
                    Button("Add") {
                        Task { await createTag() }
                    }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
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
    /// it on this note".
    private func createTag() async {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let tag = try await tagsService.createTag(named: name)
            selectedIDs.insert(tag.id)
            newTagName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        do {
            try await tagsService.setTags(Array(selectedIDs), for: item.id)
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
