import SwiftUI
import Sodium

// MARK: - VersionCompareView

/// Side-by-side-in-one-column comparison of two revisions of a note: any two snapshots, or a
/// snapshot against the editor's current text (including unsaved changes).
struct VersionCompareView: View {

    // MARK: - Source

    /// One side of the comparison.
    enum Source: Hashable {
        case current
        case version(NoteVersion)

        var title: String {
            switch self {
            case .current:             return "Current"
            case .version(let v):      return v.shortTitle
            }
        }

        var longTitle: String {
            switch self {
            case .current:             return "Current (this editor)"
            case .version(let v):      return v.displayTitle
            }
        }

        /// Cache key for the loaded text.
        var id: String {
            switch self {
            case .current:             return "current"
            case .version(let v):      return v.id
            }
        }
    }

    // MARK: - Parameters

    let item: NoteItem
    let dek: Bytes
    let versions: [NoteVersion]
    let initialVersion: NoteVersion
    let currentText: String

    // MARK: - Environment

    @EnvironmentObject var versionHistoryService: VersionHistoryService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var base: Source
    @State private var compare: Source = .current
    /// Decrypted snapshot text, keyed by `Source.id`. Snapshots are immutable, so once loaded
    /// a side can be switched back and forth without re-fetching.
    @State private var texts: [String: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?

    // MARK: - Init

    init(item: NoteItem, dek: Bytes, versions: [NoteVersion], initialVersion: NoteVersion, currentText: String) {
        self.item = item
        self.dek = dek
        self.versions = versions
        self.initialVersion = initialVersion
        self.currentText = currentText
        _base = State(initialValue: .version(initialVersion))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePickers
                Divider()
                content
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: [base.id, compare.id]) { await loadSides() }
    }

    // MARK: - Pickers

    private var sourcePickers: some View {
        HStack(spacing: 12) {
            picker(title: "From", selection: $base)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            picker(title: "To", selection: $compare)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func picker(title: String, selection: Binding<Source>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text("Current").tag(Source.current)
                ForEach(versions) { version in
                    Text(version.displayTitle).tag(Source.version(version))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await loadSides() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let baseText = texts[base.id], let compareText = texts[compare.id] {
            diffView(TextDiff.compare(baseText, compareText))
        } else {
            EmptyView()
        }
    }

    private func diffView(_ lines: [TextDiff.Line]) -> some View {
        let added = lines.filter { $0.kind == .inserted }.count
        let removed = lines.filter { $0.kind == .deleted }.count
        return VStack(spacing: 0) {
            summaryBar(added: added, removed: removed)
            if added == 0 && removed == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "equal.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("These versions are identical.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            diffLine(line)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func summaryBar(added: Int, removed: Int) -> some View {
        HStack(spacing: 12) {
            Text(base.longTitle)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("+\(added)")
                .foregroundStyle(.green)
            Text("−\(removed)")
                .foregroundStyle(.red)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func diffLine(_ line: TextDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker(for: line.kind))
                .foregroundStyle(color(for: line.kind))
                .frame(width: 10, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .unchanged ? Color.primary : color(for: line.kind))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: line.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: line))
    }

    // MARK: - Line Styling

    private func marker(for kind: TextDiff.Kind) -> String {
        switch kind {
        case .unchanged: return " "
        case .inserted:  return "+"
        case .deleted:   return "−"
        }
    }

    private func color(for kind: TextDiff.Kind) -> Color {
        switch kind {
        case .unchanged: return .secondary
        case .inserted:  return .green
        case .deleted:   return .red
        }
    }

    private func background(for kind: TextDiff.Kind) -> Color {
        switch kind {
        case .unchanged: return .clear
        case .inserted:  return .green.opacity(0.12)
        case .deleted:   return .red.opacity(0.12)
        }
    }

    /// Colour alone can't carry the added/removed distinction for VoiceOver.
    private func accessibilityLabel(for line: TextDiff.Line) -> String {
        switch line.kind {
        case .unchanged: return line.text
        case .inserted:  return "Added: \(line.text)"
        case .deleted:   return "Removed: \(line.text)"
        }
    }

    // MARK: - Loading

    private func loadSides() async {
        isLoading = true
        loadError = nil
        texts[Source.current.id] = currentText
        do {
            for source in [base, compare] {
                guard case .version(let version) = source, texts[source.id] == nil else { continue }
                texts[source.id] = try await versionHistoryService.versionText(
                    fileID: item.id, versionID: version.id, dek: dek
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
