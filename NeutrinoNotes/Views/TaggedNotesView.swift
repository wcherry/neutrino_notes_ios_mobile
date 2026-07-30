import SwiftUI

// MARK: - TaggedNotesView

/// The notes carrying one tag. Pushed from `TagsView` onto the Notes tab's navigation stack, so
/// tapping a note lands in the editor through the destination that stack already registers.
struct TaggedNotesView: View {

    // MARK: - Parameters

    let tag: NoteTag

    // MARK: - Environment

    @EnvironmentObject var tagsService: TagsService
    @EnvironmentObject var pinStore: PinStore

    // MARK: - State

    @State private var notes: [NoteItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading && notes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorView(loadError)
            } else if notes.isEmpty {
                emptyStateView
            } else {
                noteList
            }
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    // MARK: - List

    private var noteList: some View {
        List {
            ForEach(pinStore.sorted(notes)) { note in
                NavigationLink(value: note) {
                    NoteRowView(item: note, isPinned: pinStore.isPinned(note.id))
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        pinStore.togglePin(note.id)
                    } label: {
                        Label(pinStore.isPinned(note.id) ? "Unpin" : "Pin",
                              systemImage: pinStore.isPinned(note.id) ? "pin.slash" : "pin")
                    }
                    .tint(.gray)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - Empty / Error States

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tag")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("No Notes With This Tag")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Attach \u{201C}\(tag.name)\u{201D} to a note from the editor's Tags action.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .refreshable { await load() }
    }

    private func errorView(_ message: String) -> some View {
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

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            notes = try await tagsService.notes(withTag: tag.id)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TaggedNotesView(tag: NoteTag(id: "tag-1", name: "Work", createdAt: Date()))
            .environmentObject(TagsService())
            .environmentObject(PinStore())
    }
}
