import SwiftUI

// MARK: - SaveVersionSheet

/// Sheet for saving the note's current text as a named version. The name is optional —
/// Drive accepts an unlabeled snapshot — but a name is what makes a version findable later,
/// so it's the focused field.
struct SaveVersionSheet: View {

    // MARK: - Parameters

    /// Receives the trimmed name, or nil when the field was left empty.
    let onConfirm: (String?) -> Void

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var label: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $label)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Saves the note as it is now, so you can come back to it from Version History. Autosaved changes don't create a version on their own.")
                }
            }
            .navigationTitle("Save Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = label.trimmingCharacters(in: .whitespaces)
                        onConfirm(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SaveVersionSheet { label in
        print("Saving version labeled: \(label ?? "(none)")")
    }
}
