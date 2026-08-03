import Foundation
import Sodium
import os.log

// MARK: - SharingError

enum SharingError: LocalizedError {
    case notAuthenticated
    case notOwner
    case userNotFound(String)
    case cannotShareWithYourself
    case noContentService
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "You are not signed in."
        case .notOwner:                return "Only the owner can manage sharing for this item."
        case .userNotFound(let email): return "No Neutrino account found for \u{201C}\(email)\u{201D}."
        case .cannotShareWithYourself: return "You already own this — there is nothing to share with yourself."
        case .noContentService:        return "Encryption is unavailable, so the note's key can't be shared."
        case .networkError:            return "A network error occurred. Please check your connection."
        case .serverError(let code):   return "Server error (\(code))."
        case .decodingError(let err):  return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - SharingService

// Shares notes and folders with other Neutrino accounts through Drive's existing permissions,
// directory, and encryption-key APIs — the Notes app stores nothing of its own.
//
// Sharing an end-to-end encrypted note is two operations, and both have to happen:
//
//   1. `POST /drive/{files,folders}/{id}/permissions` — the recipient may now fetch the bytes.
//   2. The note's DEK, unsealed on this device and re-sealed to the recipient's public key, is
//      handed to `POST /drive/files/{id}/key/share` — the recipient may now read them.
//
// Step 2 is impossible for someone who has not imported their encryption keys yet: there is no
// public key to seal to. That is reported rather than swallowed, because the only fix is for the
// recipient to import a key and for the owner to send it again.
//
// All crypto lives in NoteContentService, which owns the Sodium instance and the Keychain key
// pair; this service orchestrates HTTP and never handles key material beyond passing it along.
@MainActor
final class SharingService: ObservableObject {

    // MARK: - KeyStatus

    /// Whether a user has an encryption key registered with Neutrino Auth, and so whether they can
    /// be given a readable copy of an encrypted note.
    enum KeyStatus: Equatable {
        case present
        case missing
    }

    // MARK: - ShareResult

    /// What a share attempt actually achieved. Sharing a folder touches every note inside it, and
    /// individual notes can fail independently, so the outcome is a count rather than a boolean —
    /// "shared 12 of 14 notes" is the truth the user needs.
    struct ShareResult: Equatable {
        var notesShared = 0
        var notesFailed = 0
        var keysDelivered = 0
        /// True when the recipient has no registered public key, so nothing they were given is
        /// readable yet.
        var recipientHasNoKey = false

        var summary: String? {
            if recipientHasNoKey {
                return "Shared, but this person hasn't set up encryption keys yet, so they can't read it. Send the key once they have."
            }
            if notesFailed > 0 {
                return "Shared \(notesShared) of \(notesShared + notesFailed) notes — the rest couldn't be shared."
            }
            if notesShared > 1 {
                return "Shared \(notesShared) notes in this folder."
            }
            return nil
        }
    }

    // MARK: - Published State

    /// Permissions per resource, keyed by `resourceKey(for:)`. Only ever populated for items this
    /// account owns — the server answers 403 to anybody else.
    @Published private(set) var permissionsByResource: [String: [SharePermission]] = [:]
    /// Whether each user known to this session has an encryption key registered.
    @Published private(set) var keyStatusByUserID: [String: KeyStatus] = [:]

    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Test Seeding

    #if DEBUG
    /// Seed state for unit tests — bypasses the network entirely.
    convenience init(permissions: [String: [SharePermission]] = [:],
                     keyStatus: [String: KeyStatus] = [:]) {
        self.init()
        self.permissionsByResource = permissions.mapValues { $0.sorted(by: SharePermission.byRoleThenName) }
        self.keyStatusByUserID = keyStatus
    }
    #endif

    // MARK: - Dependencies

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?
    /// Set once at app launch. Owns the Sodium instance and the Keychain key pair, so every
    /// unseal/re-seal of a note's DEK goes through it.
    weak var noteContentService: NoteContentService?

    // MARK: - Private

    /// A folder share expands into the notes it contains; this bounds how deep that walk goes, so
    /// a cycle in corrupt data can't spin forever. Drive's own permission inheritance uses 50.
    private static let maxFolderDepth = 20

    private static let decoder: JSONDecoder = DriveDate.makeDecoder()

    /// Public keys already fetched this session, so re-sharing several notes with the same person
    /// costs one directory lookup rather than one per note.
    private var publicKeysByUserID: [String: String] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "SharingService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Queries

    /// Cached permissions for an item. Empty until `loadPermissions(for:)` has run for it.
    func permissions(for item: NoteItem) -> [SharePermission] {
        permissionsByResource[Self.resourceKey(for: item)] ?? []
    }

    /// The people this item is shared *with* — everyone but its owner, which is this account.
    func collaborators(for item: NoteItem) -> [SharePermission] {
        permissions(for: item).filter { $0.role != .owner }
    }

    /// The owner's user id, learned from the permission list. Only an owner can read that list, so
    /// this is this account's own id — which is how a share sheet can refuse to share with the
    /// signed-in user without a separate `/auth/me` call.
    func ownerUserID(for item: NoteItem) -> String? {
        permissions(for: item).first { $0.role == .owner }?.userID
    }

    func keyStatus(for userID: String) -> KeyStatus? {
        keyStatusByUserID[userID]
    }

    /// The REST path segment for an item's resource type. Files and folders have parallel
    /// permission endpoints that differ only here.
    static func resourcePath(for item: NoteItem) -> String {
        item.type == .folder ? "folders" : "files"
    }

    /// Cache key for one resource: type-qualified, because a file and a folder could in principle
    /// carry the same id.
    static func resourceKey(for item: NoteItem) -> String {
        "\(resourcePath(for: item)):\(item.id)"
    }

    // MARK: - Permission List

    /// Loads who has access to an item. A 403 means this account is not the owner, which the sheet
    /// shows as an explanation rather than a failure — Drive allows only owners to see the list.
    func loadPermissions(for item: NoteItem) async {
        logger.debug("loadPermissions: \(Self.resourceKey(for: item), privacy: .public)")
        isLoading = true
        error = nil
        do {
            let path = "/api/v1/drive/\(Self.resourcePath(for: item))/\(item.id)/permissions"
            let response: APIListPermissionsResponse = try await get(path)
            let sorted = response.permissions.sorted(by: SharePermission.byRoleThenName)
            permissionsByResource[Self.resourceKey(for: item)] = sorted
            logger.debug("loadPermissions: \(sorted.count) permission(s)")
            await refreshKeyStatuses(for: sorted)
        } catch SharingError.serverError(statusCode: 403) {
            logger.error("loadPermissions: not the owner of \(item.id, privacy: .public)")
            self.error = SharingError.notOwner.localizedDescription
        } catch {
            logger.error("loadPermissions failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Fills in whether each collaborator can receive an encrypted note at all. One directory
    /// lookup per person, cached for the session; a share list is a handful of people, and the
    /// answer is what the "can't read this" warning is made of.
    private func refreshKeyStatuses(for permissions: [SharePermission]) async {
        for permission in permissions where permission.role != .owner {
            guard keyStatusByUserID[permission.userID] == nil else { continue }
            _ = try? await publicKey(for: permission.userID)
        }
    }

    // MARK: - Sharing

    /// Shares an item with one person: grants the permission, then makes what was granted readable.
    ///
    /// For a note that is one permission and one key re-wrap. For a folder it is the folder grant
    /// (which is what gives inherited access to anything added later) *plus* the same treatment for
    /// every note inside it, because Drive's folder listings are owner-scoped: without per-note
    /// permissions the recipient would see a folder they cannot open and notes they cannot find.
    ///
    /// The grant is done first deliberately — a failed key share is recoverable with **Send Key**,
    /// while a failed grant means no access at all.
    @discardableResult
    func share(_ item: NoteItem, with user: DirectoryUser, role: ShareRole) async throws -> ShareResult {
        guard user.id != ownerUserID(for: item) else { throw SharingError.cannotShareWithYourself }
        logger.debug("share: \(Self.resourceKey(for: item), privacy: .public) with=\(user.id, privacy: .public) role=\(role.rawValue, privacy: .public)")

        let permission = try await grant(item, to: user, role: role)
        insert(permission, for: item)

        var result = ShareResult()
        if item.type == .file {
            result.notesShared = 1
            switch try await shareKey(fileID: item.id, with: user.id) {
            case .delivered:         result.keysDelivered = 1
            case .recipientHasNoKey: result.recipientHasNoKey = true
            case .filePlaintext:     break
            }
        } else {
            result = try await applyToFolderContents(item, user: user, role: role)
        }
        logger.debug("share finished: notes=\(result.notesShared) failed=\(result.notesFailed) keys=\(result.keysDelivered)")
        return result
    }

    /// Re-applies an existing collaborator's access to everything currently inside a folder.
    ///
    /// A note added after the folder was shared has no permission row and no re-wrapped key of its
    /// own, and the server cannot create one — a DEK can only be re-sealed on a device that can
    /// unseal it. So catching up is necessarily a manual action by the owner, and this is it.
    @discardableResult
    func reshareFolderContents(_ item: NoteItem, with permission: SharePermission) async throws -> ShareResult {
        guard item.type == .folder else { return ShareResult() }
        let user = DirectoryUser(id: permission.userID, email: permission.userEmail, name: permission.userName)
        return try await applyToFolderContents(item, user: user, role: permission.role)
    }

    /// Grants `role` on every note inside `folder` and re-wraps each note's key for `user`.
    /// Individual notes are allowed to fail: the folder-level grant has already succeeded, and
    /// aborting halfway would leave the user unable to tell what got through.
    private func applyToFolderContents(_ folder: NoteItem,
                                       user: DirectoryUser,
                                       role: ShareRole) async throws -> ShareResult {
        var result = ShareResult()
        let noteIDs = try await noteIDs(inFolder: folder.id)
        logger.debug("applyToFolderContents: \(noteIDs.count) note(s) under \(folder.id, privacy: .public)")

        for noteID in noteIDs {
            do {
                let note = NoteItem(id: noteID, name: "", type: .file, parentID: folder.id,
                                    size: nil, modifiedAt: Date(), isTrashed: false,
                                    mimeType: NoteItem.markdownMIME)
                _ = try await grant(note, to: user, role: role)
                result.notesShared += 1
                switch try await shareKey(fileID: noteID, with: user.id) {
                case .delivered:         result.keysDelivered += 1
                case .recipientHasNoKey: result.recipientHasNoKey = true
                case .filePlaintext:     break
                }
            } catch {
                logger.error("applyToFolderContents: note=\(noteID, privacy: .public) failed: \(error, privacy: .public)")
                result.notesFailed += 1
            }
        }
        return result
    }

    /// Changes somebody's role, optimistically, rolling back if the server refuses.
    func updateRole(of permission: SharePermission, on item: NoteItem, to role: ShareRole) {
        guard permission.role != role else { return }
        logger.debug("updateRole: \(permission.userID, privacy: .public) to=\(role.rawValue, privacy: .public)")
        apply(role: role, toUserID: permission.userID, on: item)
        Task {
            do {
                let path = "/api/v1/drive/\(Self.resourcePath(for: item))/\(item.id)/permissions/\(permission.userID)"
                let _: SharePermission = try await patch(path, body: APIUpdatePermissionRequest(role: role))
                logger.debug("updateRole succeeded: \(permission.userID, privacy: .public)")
            } catch {
                logger.error("updateRole failed: \(error, privacy: .public)")
                apply(role: permission.role, toUserID: permission.userID, on: item)
                self.error = error.localizedDescription
            }
        }
    }

    /// Removes somebody's access, optimistically. The server also deletes their key ref, so the
    /// note stops being readable as well as reachable.
    func revoke(_ permission: SharePermission, on item: NoteItem) {
        logger.debug("revoke: \(permission.userID, privacy: .public) from \(Self.resourceKey(for: item), privacy: .public)")
        let key = Self.resourceKey(for: item)
        let previous = permissionsByResource[key] ?? []
        permissionsByResource[key] = previous.filter { $0.userID != permission.userID }
        Task {
            do {
                let path = "/api/v1/drive/\(Self.resourcePath(for: item))/\(item.id)/permissions/\(permission.userID)"
                try await deleteRequest(path)
                logger.debug("revoke succeeded: \(permission.userID, privacy: .public)")
            } catch {
                logger.error("revoke failed: \(error, privacy: .public)")
                permissionsByResource[key] = previous
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Encryption Keys

    /// The outcome of re-wrapping one note's key for one recipient.
    enum KeyShareResult: Equatable {
        case delivered
        /// The recipient has no public key registered, so nothing can be sealed to them yet.
        case recipientHasNoKey
        /// The file has no key ref at all — it was uploaded unencrypted, so there is nothing to
        /// share and the permission alone is enough.
        case filePlaintext
    }

    /// Unseals a note's DEK with this device's private key and re-seals it to the recipient's
    /// public key. The server never sees the DEK; it stores only the sealed result.
    @discardableResult
    func shareKey(fileID: String, with userID: String) async throws -> KeyShareResult {
        guard let content = noteContentService else { throw SharingError.noContentService }
        guard let recipientKey = try await publicKey(for: userID) else {
            logger.error("shareKey: recipient \(userID, privacy: .public) has no registered public key")
            return .recipientHasNoKey
        }
        guard let sealedForMe = try await content.sealedFileKey(for: fileID) else {
            logger.debug("shareKey: file \(fileID, privacy: .public) has no key ref — nothing to share")
            return .filePlaintext
        }
        let dek: Bytes = try content.unsealDEK(sealedForMe)
        let sealedForRecipient = try content.seal(dek, toRecipientPublicKey: recipientKey)
        try await postWithoutResponse(
            "/api/v1/drive/files/\(fileID)/key/share",
            body: APIShareFileKeyRequest(recipientId: userID, encryptedFileKey: sealedForRecipient)
        )
        logger.debug("shareKey: delivered key for \(fileID, privacy: .public) to \(userID, privacy: .public)")
        return .delivered
    }

    /// Re-sends the key for an item — one note, or every note in a folder — to somebody who
    /// already has permission. This is what fixes "shared before they imported their keys".
    @discardableResult
    func sendKey(for item: NoteItem, to permission: SharePermission) async throws -> ShareResult {
        // Their key may have appeared since it was last checked, so don't trust the cache.
        publicKeysByUserID[permission.userID] = nil
        keyStatusByUserID[permission.userID] = nil

        if item.type == .folder {
            return try await reshareFolderContents(item, with: permission)
        }
        var result = ShareResult(notesShared: 1)
        switch try await shareKey(fileID: item.id, with: permission.userID) {
        case .delivered:         result.keysDelivered = 1
        case .recipientHasNoKey: result.recipientHasNoKey = true
        case .filePlaintext:     break
        }
        return result
    }

    /// A user's registered Curve25519 public key, or nil when they have not imported one. Cached
    /// per session, including the "no key" answer, which the share sheet renders as a warning.
    func publicKey(for userID: String) async throws -> String? {
        if let cached = publicKeysByUserID[userID] { return cached }
        if keyStatusByUserID[userID] == .missing { return nil }
        do {
            let response: APIPublicKeyResponse = try await get("/api/v1/auth/users/\(userID)/public-key")
            publicKeysByUserID[userID] = response.publicKey
            keyStatusByUserID[userID] = .present
            return response.publicKey
        } catch SharingError.serverError(statusCode: 404) {
            keyStatusByUserID[userID] = .missing
            return nil
        }
    }

    // MARK: - Directory

    /// Finds the account to share with. Matching is by exact email, which is what the grant
    /// endpoint needs anyway (it wants id, email and name together).
    func lookupUser(email: String) async throws -> DirectoryUser {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SharingError.userNotFound(trimmed)
        }
        do {
            return try await get("/api/v1/auth/users/lookup?email=\(encoded)")
        } catch SharingError.serverError(statusCode: 404) {
            throw SharingError.userNotFound(trimmed)
        }
    }

    /// Type-ahead over the account directory. Empty queries are answered locally rather than
    /// asking the server for everybody.
    func searchUsers(matching query: String) async throws -> [DirectoryUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        return try await get("/api/v1/auth/users/search?q=\(encoded)")
    }

    // MARK: - Folder Contents

    /// Every Markdown note inside a folder, including its subfolders.
    ///
    /// This walks the owner's own listings (`GET /drive/folders/{id}`), which is possible precisely
    /// because only an owner ever shares. Depth is capped, and folders already seen are skipped, so
    /// corrupt parentage cannot loop.
    func noteIDs(inFolder folderID: String) async throws -> [String] {
        var noteIDs: [String] = []
        var visited: Set<String> = []
        var frontier = [(id: folderID, depth: 0)]

        while let next = frontier.popLast() {
            guard next.depth < Self.maxFolderDepth, visited.insert(next.id).inserted else { continue }
            let listing: APIFolderListing = try await get("/api/v1/drive/folders/\(next.id)?type=note")
            noteIDs.append(contentsOf: listing.files.map(\.id))
            frontier.append(contentsOf: listing.folders.map { (id: $0.id, depth: next.depth + 1) })
        }
        return noteIDs
    }

    // MARK: - Private Cache Helpers

    private func grant(_ item: NoteItem, to user: DirectoryUser, role: ShareRole) async throws -> SharePermission {
        let path = "/api/v1/drive/\(Self.resourcePath(for: item))/\(item.id)/permissions"
        let body = APIGrantPermissionRequest(userId: user.id, userEmail: user.email,
                                             userName: user.name, role: role)
        return try await post(path, body: body)
    }

    /// Adds or replaces a permission in the cache, keeping the list sorted.
    private func insert(_ permission: SharePermission, for item: NoteItem) {
        let key = Self.resourceKey(for: item)
        var permissions = permissionsByResource[key] ?? []
        permissions.removeAll { $0.userID == permission.userID }
        permissions.append(permission)
        permissionsByResource[key] = permissions.sorted(by: SharePermission.byRoleThenName)
    }

    private func apply(role: ShareRole, toUserID userID: String, on item: NoteItem) {
        let key = Self.resourceKey(for: item)
        guard var permissions = permissionsByResource[key] else { return }
        for idx in permissions.indices where permissions[idx].userID == userID {
            permissions[idx].role = role
        }
        permissionsByResource[key] = permissions.sorted(by: SharePermission.byRoleThenName)
    }

    // MARK: - HTTP

    /// Builds a URLRequest without an Authorization header; `perform` injects it after refresh.
    private func request(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw SharingError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try request(method: "GET", path: path))
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(try request(method: "POST", path: path, body: body))
    }

    private func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(try request(method: "PATCH", path: path, body: body))
    }

    /// The key-share endpoint answers with a body this client has no use for.
    private func postWithoutResponse(_ path: String, body: some Encodable) async throws {
        _ = try await execute(try await authorized(try request(method: "POST", path: path, body: body)))
    }

    private func deleteRequest(_ path: String) async throws {
        // Revoking answers 204 — nothing to decode.
        _ = try await execute(try await authorized(try request(method: "DELETE", path: path)))
    }

    /// Refreshes the token if needed, injects it, executes the request, and decodes the response.
    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data = try await execute(try await authorized(req))
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public)")
            throw SharingError.decodingError(underlying: error)
        }
    }

    /// Executes an already-authorized request and returns the raw body.
    private func execute(_ req: URLRequest) async throws -> Data {
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw SharingError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SharingError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public) (\(data.count) bytes)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw SharingError.serverError(statusCode: http.statusCode)
        }
        return data
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw SharingError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - API Response / Request Models

private struct APIListPermissionsResponse: Decodable {
    let permissions: [SharePermission]
}

private struct APIGrantPermissionRequest: Encodable {
    let userId: String
    let userEmail: String
    let userName: String
    let role: ShareRole
}

private struct APIUpdatePermissionRequest: Encodable {
    let role: ShareRole
}

private struct APIShareFileKeyRequest: Encodable {
    let recipientId: String
    let encryptedFileKey: String
}

private struct APIPublicKeyResponse: Decodable {
    let userId: String
    let publicKey: String
}

/// Just enough of a folder listing to find the notes inside it.
private struct APIFolderListing: Decodable {
    struct File: Decodable {
        let id: String
        let mimeType: String
    }
    struct Folder: Decodable {
        let id: String
    }
    let files: [File]
    let folders: [Folder]
}
