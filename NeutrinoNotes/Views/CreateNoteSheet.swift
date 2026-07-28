import SwiftUI

// MARK: - CreateNoteSheet

/// Sheet for creating a new Markdown note inside a given parent directory.
/// Automatically appends a ".md" extension if the user doesn't type one.
struct CreateNoteSheet: View {

    // MARK: - Parameters

    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void

    // MARK: - State

    @State private var name: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note name", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Saved as \(resolvedName.isEmpty ? "Untitled.md" : resolvedName)")
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onConfirm(resolvedName.isEmpty ? "Untitled.md" : resolvedName)
                        isPresented = false
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }
}

// MARK: - Preview

#Preview {
    CreateNoteSheet(isPresented: .constant(true)) { name in
        print("Create note: \(name)")
    }
}
