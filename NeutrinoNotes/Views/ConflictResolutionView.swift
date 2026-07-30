import SwiftUI

// MARK: - ConflictResolutionView

/// Presented when a note's server copy has advanced past what this device last knew about while
/// this device still has an unsynced local edit. Exactly one of three explicit choices — no
/// auto-merge, no last-write-wins. Kept simple and consistent with `NoteEditorView`'s existing
/// empty/error-state visual language (SF Symbols, centered stack, `.secondary` explanatory text).
struct ConflictResolutionView: View {
    let conflict: SyncConflict
    let onResolve: (ConflictChoice) -> Void

    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                VStack(spacing: 4) {
                    Text("Sync Conflict")
                        .font(.headline)
                    Text("\u{201C}\(conflict.itemName)\u{201D} was changed elsewhere since you started editing. Choose how to resolve it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    choiceButton(
                        title: "Keep Mine",
                        subtitle: "Overwrite the server with your local changes.",
                        systemImage: "iphone",
                        choice: .keepMine
                    )
                    choiceButton(
                        title: "Keep Server",
                        subtitle: "Discard your local changes and load the server's version.",
                        systemImage: "icloud",
                        choice: .keepServer
                    )
                    choiceButton(
                        title: "Keep Both (Fork)",
                        subtitle: "Save the server's version as a new note; keep editing yours here.",
                        systemImage: "doc.on.doc",
                        choice: .fork
                    )
                }
                .padding(.horizontal)

                if isResolving {
                    ProgressView()
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }

    private func choiceButton(title: String, subtitle: String, systemImage: String, choice: ConflictChoice) -> some View {
        Button {
            isResolving = true
            onResolve(choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
    }
}

// MARK: - Preview

#Preview {
    ConflictResolutionView(
        conflict: SyncConflict(
            id: UUID(), itemID: "f1", itemName: "Meeting Notes.md", parentID: nil,
            serverModifiedAt: Date(), localModifiedAt: Date().addingTimeInterval(-120), detectedAt: Date()
        ),
        onResolve: { _ in }
    )
}
