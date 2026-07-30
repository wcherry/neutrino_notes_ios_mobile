import SwiftUI
import Sodium

// MARK: - VersionHistoryView

/// Sheet listing a note's previous versions, with restore and compare.
///
/// Presented from the editor, which is where the note's DEK is already in hand — snapshots
/// are ciphertext and need that key to be read or written.
struct VersionHistoryView: View {

    // MARK: - Parameters

    let item: NoteItem
    /// The note's DEK, held by the editing session.
    let dek: Bytes
    /// The editor's current text, including unsaved changes — the right-hand side of a compare.
    let currentText: String
    /// Called after a successful restore, with the note's new server-side modification date and
    /// size, so the editor can reload its content and refresh what the browser shows.
    let onRestore: (Date, Int64) -> Void

    // MARK: - Environment

    @EnvironmentObject var versionHistoryService: VersionHistoryService
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var versions: [NoteVersion] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var versionToRestore: NoteVersion?
    @State private var isRestoring = false
    @State private var comparison: Comparison?

    /// Identifies the compare sheet by the version it was opened from.
    private struct Comparison: Identifiable {
        let version: NoteVersion
        var id: String { version.id }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Version History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await load() }
        .sheet(item: $comparison) { comparison in
            VersionCompareView(
                item: item,
                dek: dek,
                versions: versions,
                initialVersion: comparison.version,
                currentText: currentText
            )
        }
        .confirmationDialog(
            versionToRestore.map { "Restore \($0.displayTitle)?" } ?? "",
            isPresented: Binding(get: { versionToRestore != nil }, set: { if !$0 { versionToRestore = nil } }),
            titleVisibility: .visible,
            presenting: versionToRestore
        ) { version in
            Button("Restore") { Task { await restore(version) } }
            Button("Cancel", role: .cancel) { versionToRestore = nil }
        } message: { _ in
            Text("The note's current content is saved as a new version first, so this can be undone.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            messageView(
                icon: "exclamationmark.triangle",
                message: loadError,
                actionTitle: "Retry",
                action: { Task { await load() } }
            )
        } else if versions.isEmpty {
            messageView(
                icon: "clock.arrow.circlepath",
                message: "No previous versions yet. Choose “Save Version” while editing to keep a snapshot you can come back to.",
                actionTitle: nil,
                action: nil
            )
        } else {
            versionList
        }
    }

    private var versionList: some View {
        List {
            Section {
                ForEach(versions) { version in
                    row(for: version)
                }
            } footer: {
                Text("Autosaved changes don't create a version. Use “Save Version” in the editor to keep a snapshot.")
            }
        }
        .disabled(isRestoring)
        .overlay {
            if isRestoring {
                ProgressView("Restoring…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func row(for version: NoteVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(version.displayTitle)
                    .font(.headline)
                if version.isNamed {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Saved version")
                }
            }
            Text("\(version.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(byteFormatter.string(fromByteCount: version.sizeBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            Button("Restore") { versionToRestore = version }
                .tint(.orange)
        }
        .contextMenu {
            Button {
                comparison = Comparison(version: version)
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
            Button {
                versionToRestore = version
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward.circle")
            }
        }
        .onTapGesture {
            comparison = Comparison(version: version)
        }
    }

    private func messageView(icon: String, message: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        guard networkMonitor.isOnline else {
            loadError = "Version history needs a connection. Previous versions aren't stored on this device."
            isLoading = false
            return
        }
        do {
            versions = try await versionHistoryService.listVersions(fileID: item.id)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func restore(_ version: NoteVersion) async {
        versionToRestore = nil
        isRestoring = true
        do {
            let restored = try await versionHistoryService.restore(versionID: version.id, fileID: item.id)
            isRestoring = false
            onRestore(restored.modifiedAt, restored.sizeBytes)
            dismiss()
        } catch {
            isRestoring = false
            loadError = error.localizedDescription
        }
    }
}
