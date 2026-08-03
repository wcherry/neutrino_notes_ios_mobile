import SwiftUI

// MARK: - TagsView

/// The Tags section of the Notes tab: every tag the user owns, with create, rename, and delete.
/// Tapping a tag pushes the notes carrying it (`TaggedNotesView`).
struct TagsView: View {

    // MARK: - Environment

    @EnvironmentObject var tagsService: TagsService

    // MARK: - State

    @State private var showCreateTag = false
    @State private var tagToRename: NoteTag?
    @State private var tagToDelete: NoteTag?
    @State private var createError: String?

    // MARK: - Body

    var body: some View {
        Group {
            if tagsService.isLoading && tagsService.tags.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tagsService.tags.isEmpty {
                emptyStateView
            } else {
                tagList
            }
        }
        .navigationTitle(NotesSection.tags.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateTag = true
                } label: {
                    Label("New Tag", systemImage: "plus")
                }
            }
        }
        .task { await tagsService.loadTags() }
        .sheet(isPresented: $showCreateTag) {
            TagNameSheet(title: "New Tag", initialName: "") { name in
                Task {
                    do {
                        try await tagsService.createTag(named: name)
                    } catch {
                        createError = error.localizedDescription
                    }
                }
            }
        }
        .sheet(item: $tagToRename) { tag in
            TagNameSheet(title: "Rename Tag", initialName: tag.name) { name in
                tagsService.renameTag(tag, to: name)
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(tagToDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tag = tagToDelete { tagsService.deleteTag(tag) }
                tagToDelete = nil
            }
            Button("Cancel", role: .cancel) { tagToDelete = nil }
        } message: {
            Text("The tag is removed from every note that carries it. The notes themselves are not deleted.")
        }
        .alert("Couldn't Create Tag", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK") { createError = nil }
        } message: {
            Text(createError ?? "")
        }
        .alert("Error", isPresented: Binding(
            get: { tagsService.error != nil },
            set: { if !$0 { tagsService.error = nil } }
        )) {
            Button("OK") { tagsService.error = nil }
        } message: {
            Text(tagsService.error ?? "")
        }
    }

    // MARK: - List

    private var tagList: some View {
        List {
            ForEach(tagsService.tags) { tag in
                NavigationLink(value: tag) {
                    HStack {
                        Label(tag.name, systemImage: "tag")
                        Spacer()
                        // The server counts every non-trashed *file* carrying the tag, so a tag
                        // also used on a non-Markdown file in Drive counts higher than the notes
                        // listed when it is tapped. Unused tags show nothing rather than a zero.
                        if tag.fileCount > 0 {
                            Text("\(tag.fileCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(tag.fileCount) files")
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        tagToDelete = tag
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        tagToRename = tag
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        tagToRename = tag
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        tagToDelete = tag
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await tagsService.loadTags() }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tag")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("No Tags Yet")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Tags group notes across folders. Create one here, then attach it to a note from its editor.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable { await tagsService.loadTags() }
    }
}

// MARK: - TagNameSheet

/// Shared create/rename sheet — the two differ only in title and starting value.
struct TagNameSheet: View {

    // MARK: - Parameters

    let title: String
    let initialName: String
    let onConfirm: (String) -> Void

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var name: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tag name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Tag names are stored unencrypted, like note titles. Note contents stay encrypted.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onConfirm(name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(isSaveDisabled)
                }
            }
            .onAppear { name = initialName }
        }
    }

    // MARK: - Helpers

    private var isSaveDisabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == initialName
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TagsView()
            .environmentObject(TagsService())
    }
}
