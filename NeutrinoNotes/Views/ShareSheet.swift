import SwiftUI

// MARK: - ShareSheet

/// Shares one note or folder with other Neutrino accounts, and manages who already has access.
///
/// Owner-only by construction: Drive answers 403 to anyone else asking who a resource is shared
/// with, so this sheet is offered only for items this account owns and says so plainly if the
/// server disagrees.
///
/// Two things about sharing an end-to-end encrypted note are surfaced here rather than hidden:
/// a recipient who has not imported their encryption keys cannot be given a readable note (their
/// row says so, and **Send Key** fixes it once they have), and sharing a *folder* also shares each
/// note inside it, because Drive cannot list someone else's folder for them.
struct ShareSheet: View {

    // MARK: - Parameters

    let item: NoteItem

    // MARK: - Environment

    @EnvironmentObject var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var query = ""
    @State private var searchResults: [DirectoryUser] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var role: ShareRole = .editor
    @State private var isLoading = true
    @State private var isSharing = false
    @State private var busyUserID: String?
    @State private var statusMessage: String?
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
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Sharing", isPresented: Binding(
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
            addPeopleSection
            peopleWithAccessSection
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            encryptionFooterSection
        }
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search by name or email")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: query) { newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Add People

    @ViewBuilder
    private var addPeopleSection: some View {
        Section {
            Picker("Role", selection: $role) {
                ForEach(ShareRole.grantable) { grantable in
                    Text(grantable.label).tag(grantable)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSharing)

            if searchResults.isEmpty {
                Text(searchPromptText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults) { user in
                    Button {
                        Task { await share(with: user) }
                    } label: {
                        personRow(title: user.displayName, detail: user.displayDetail,
                                  systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(isSharing)
                }
            }
        } header: {
            Text(item.name.isEmpty ? "Share" : item.name)
        } footer: {
            Text(role.summary + (item.type == .folder ? " · applied to every note in this folder" : ""))
        }
    }

    /// What the add-people section says when there is nothing to list — which is most of the time,
    /// since a two-character minimum keeps the directory from being queried on every keystroke.
    private var searchPromptText: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Type a name or email address to find someone to share with." }
        if trimmed.count < 2 { return "Keep typing…" }
        return "No accounts match \u{201C}\(trimmed)\u{201D}."
    }

    // MARK: - People With Access

    @ViewBuilder
    private var peopleWithAccessSection: some View {
        Section {
            if sharingService.permissions(for: item).isEmpty {
                Text(sharingService.error ?? "Not shared with anyone yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sharingService.permissions(for: item)) { permission in
                    permissionRow(permission)
                }
            }
        } header: {
            Text("People with access")
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: SharePermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                personRow(title: permission.displayName,
                          detail: permission.displayDetail,
                          systemImage: permission.role.iconName)
                Spacer()
                if busyUserID == permission.userID {
                    ProgressView()
                } else if permission.role == .owner {
                    // The owner is this account — only an owner can see this list at all.
                    Text("Owner (you)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    roleMenu(for: permission)
                }
            }
            if permission.role != .owner, sharingService.keyStatus(for: permission.userID) == .missing {
                missingKeyNotice(for: permission)
            }
        }
    }

    private func roleMenu(for permission: SharePermission) -> some View {
        Menu {
            ForEach(ShareRole.grantable) { grantable in
                Button {
                    sharingService.updateRole(of: permission, on: item, to: grantable)
                } label: {
                    Label(grantable.label, systemImage: grantable == permission.role ? "checkmark" : grantable.iconName)
                }
            }
            Divider()
            Button {
                Task { await sendKey(to: permission) }
            } label: {
                Label(item.type == .folder ? "Re-share Folder Contents" : "Send Key", systemImage: "key")
            }
            Divider()
            Button(role: .destructive) {
                sharingService.revoke(permission, on: item)
            } label: {
                Label("Remove Access", systemImage: "person.crop.circle.badge.xmark")
            }
        } label: {
            Text(permission.role.label)
                .font(.caption)
        }
    }

    /// The one thing a permission alone cannot fix: no public key means nothing can be sealed for
    /// this person, so they hold a note they cannot read until the owner sends the key again.
    private func missingKeyNotice(for permission: SharePermission) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("Hasn't set up encryption keys — can't read this yet.")
            Spacer()
            Button("Send Key") {
                Task { await sendKey(to: permission) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }

    private func personRow(title: String, detail: String?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var encryptionFooterSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        let base = "Notes stay end-to-end encrypted: sharing re-wraps this note's key for each person on this device, so the server never sees it. Names and titles are not encrypted. There is no public share link — a link recipient would have no key and would only get an unreadable file."
        guard item.type == .folder else { return base }
        return base + "\n\nSharing a folder also shares each note inside it, because Drive can't list someone else's folder. A note added later needs \u{201C}Re-share Folder Contents\u{201D}."
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        await sharingService.loadPermissions(for: item)
        isLoading = false
    }

    /// Debounced directory search — one request after typing settles, not one per keystroke.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await sharingService.searchUsers(matching: text)
                guard !Task.isCancelled else { return }
                searchResults = filtered(results)
            } catch {
                searchResults = []
            }
        }
    }

    /// Drops people who already have access, and this account itself — sharing with either is a
    /// server-side error, and offering it would be an invitation to hit one.
    private func filtered(_ users: [DirectoryUser]) -> [DirectoryUser] {
        let existing = Set(sharingService.permissions(for: item).map(\.userID))
        return users.filter { !existing.contains($0.id) }
    }

    private func share(with user: DirectoryUser) async {
        isSharing = true
        statusMessage = nil
        do {
            let result = try await sharingService.share(item, with: user, role: role)
            statusMessage = result.summary ?? "Shared with \(user.displayName)."
            query = ""
            searchResults = []
        } catch {
            errorMessage = error.localizedDescription
        }
        isSharing = false
    }

    private func sendKey(to permission: SharePermission) async {
        busyUserID = permission.userID
        statusMessage = nil
        do {
            let result = try await sharingService.sendKey(for: item, to: permission)
            statusMessage = result.summary
                ?? "Sent the key to \(permission.displayName) — they can read this now."
        } catch {
            errorMessage = error.localizedDescription
        }
        busyUserID = nil
    }
}

// MARK: - Preview

#Preview {
    ShareSheet(item: NoteItem(
        id: "preview",
        name: "Meeting Notes.md",
        type: .file,
        parentID: nil,
        size: 1024,
        modifiedAt: Date(),
        isTrashed: false,
        mimeType: NoteItem.markdownMIME
    ))
    .environmentObject(SharingService())
}
