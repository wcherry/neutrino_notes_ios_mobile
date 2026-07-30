import Foundation
import os.log

// MARK: - NotesDriveError

enum NotesDriveError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:           return "You are not signed in."
        case .networkError:               return "A network error occurred. Please check your connection."
        case .serverError(let code):      return "Server error (\(code))."
        case .decodingError(let err):     return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - NotesDriveService

// Browses and organizes the Markdown documents stored in Neutrino Drive. Reuses the existing
// Drive folder/file/trash APIs — the Notes app has no backend of its own — and filters every
// response down to folders and Drive's note MIME type (see NoteItem.isVisibleInNotes).
@MainActor
final class NotesDriveService: ObservableObject {

    // MARK: - Published State

    /// My Notes items (hierarchical). Also used by MoveSheet for folder picker.
    @Published private(set) var allItems: [NoteItem] = []
    /// Items from GET /api/v1/drive/trash, filtered to folders and Markdown files.
    @Published private(set) var trashItems: [NoteItem] = []
    /// Epic 12: starred folders and notes from GET /api/v1/drive?view=starred, most recently
    /// starred first (the server orders by `starred_at` descending).
    @Published private(set) var starredItems: [NoteItem] = []
    /// Epic 12: most recently modified notes from GET /api/v1/drive?view=recent.
    @Published private(set) var recentItems: [NoteItem] = []

    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Test Seeding

    #if DEBUG
    /// Seed state for unit tests — bypasses the network entirely.
    convenience init(myNotes: [NoteItem] = [], trash: [NoteItem] = [],
                     starred: [NoteItem] = [], recents: [NoteItem] = []) {
        self.init()
        self.allItems = myNotes
        self.trashItems = trash
        self.starredItems = starred
        self.recentItems = recents
    }
    #endif

    // MARK: - Shared decoder

    private static let decoder: JSONDecoder = {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                            category: "NotesDriveService")
        return DriveDate.makeDecoder(convertFromSnakeCase: true) { raw in
            logger.error("date decode failed: unexpected value=\(raw, privacy: .public)")
        }
    }()

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "NotesDriveService")

    // MARK: - Configuration

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    /// Set once at app launch. Metadata-only writes (rename, star) bump the server's `updatedAt`
    /// without changing a note's content, which SyncEngine would otherwise read as somebody else
    /// having edited the note — see `OfflineStore.rebasePendingEdit`.
    weak var offlineStore: OfflineStore?

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Section Query

    func items(in section: NotesSection, parentID: String?) -> [NoteItem] {
        switch section {
        case .myNotes: return allItems.filter { $0.parentID == parentID }
        // Tags browse tags, not items; TagsView owns that listing (see NotesSection.tags).
        case .tags:    return []
        case .trash:   return trashItems
        }
    }

    /// Looks an item up wherever it currently lives. A note reached from Favorites or Recents was
    /// never part of a folder listing, so `allItems` alone would not find it.
    func item(id: String) -> NoteItem? {
        allItems.first(where: { $0.id == id })
            ?? starredItems.first(where: { $0.id == id })
            ?? recentItems.first(where: { $0.id == id })
            ?? trashItems.first(where: { $0.id == id })
    }

    // MARK: - Load

    func loadSection(_ section: NotesSection, parentID: String?) async {
        logger.debug("loadSection: \(section.rawValue, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        isLoading = true
        error = nil
        do {
            switch section {
            case .myNotes:
                let response: APIFolderContentsResponse
                if let id = parentID {
                    // /folders/{id} has no server-side type filter — rely on the client-side
                    // isVisibleInNotes filter below.
                    response = try await get("/api/v1/drive/folders/\(id)")
                } else {
                    // Root listing supports filtering to a single MIME-mapped type server-side.
                    response = try await get("/api/v1/drive?type=note")
                }
                let folders = response.folders.map { NoteItem(folder: $0) }
                let allFiles = response.files.map { NoteItem(file: $0) }
                let files = allFiles.filter(NoteItem.isVisibleInNotes)
                logger.debug("loadSection myNotes: API returned \(response.folders.count) folders, \(response.files.count) files: \(allFiles.map { "\($0.name) [\($0.mimeType ?? "nil")]" }.joined(separator: ", "), privacy: .public)")
                if allFiles.count != files.count {
                    let dropped = allFiles.filter { !NoteItem.isVisibleInNotes($0) }
                    logger.debug("loadSection myNotes: filtered out \(dropped.count) non-Markdown file(s): \(dropped.map { "\($0.name) [\($0.mimeType ?? "nil")]" }.joined(separator: ", "), privacy: .public)")
                }
                // Replace cached items for this parent to avoid stale duplicates.
                allItems.removeAll { $0.parentID == parentID }
                allItems.append(contentsOf: folders)
                allItems.append(contentsOf: files)
                logger.debug("loadSection myNotes: displaying \(folders.count) folders, \(files.count) Markdown files")

            case .tags:
                // Nothing to fetch here — TagsService loads the tag list.
                break

            case .trash:
                let response: APITrashContentsResponse = try await get("/api/v1/drive/trash")
                let folders = response.folders.map { NoteItem(trashFolder: $0) }
                let allFiles = response.files.map { NoteItem(trashFile: $0) }
                let files = allFiles.filter(NoteItem.isVisibleInNotes)
                logger.debug("loadSection trash: API returned \(response.folders.count) folders, \(response.files.count) files: \(allFiles.map { "\($0.name) [\($0.mimeType ?? "nil")]" }.joined(separator: ", "), privacy: .public)")
                trashItems = folders + files
                logger.debug("loadSection trash: displaying \(folders.count) folders, \(files.count) Markdown files")
            }
        } catch {
            logger.error("loadSection \(section.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Epic 12 Listings

    /// Loads the Favorites listing: every starred folder and note, most recently starred first.
    ///
    /// `?view=starred` and `?type=note` cannot be combined — the server checks `type` first and
    /// returns before it looks at `view` — so the response is reduced to folders and Markdown
    /// files here, with the same predicate the folder listing uses.
    func loadStarred() async {
        logger.debug("loadStarred")
        isLoading = true
        error = nil
        do {
            let response: APIFolderContentsResponse = try await get("/api/v1/drive?view=starred")
            let folders = response.folders.map { NoteItem(folder: $0) }
            let files = response.files.map { NoteItem(file: $0) }.filter(NoteItem.isVisibleInNotes)
            starredItems = folders + files
            logger.debug("loadStarred: \(folders.count) folders, \(files.count) notes")
        } catch {
            logger.error("loadStarred failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Loads the Recents listing: the most recently modified notes, newest first. Trashed items
    /// are excluded server-side. Folders are never part of this view — the server returns files
    /// only — so Recents is a flat list of notes.
    func loadRecents(limit: Int = 50) async {
        logger.debug("loadRecents: limit=\(limit)")
        isLoading = true
        error = nil
        do {
            let response: APIFolderContentsResponse = try await get("/api/v1/drive?view=recent&limit=\(limit)")
            recentItems = response.files.map { NoteItem(file: $0) }.filter(NoteItem.isVisibleInNotes)
            logger.debug("loadRecents: \(self.recentItems.count) of \(response.files.count) recent files are notes")
        } catch {
            logger.error("loadRecents failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Mutations (fire-and-forget, optimistic)

    /// Stars or unstars an item — the Favorites model, shared with the web app, which stores the
    /// flag on the Drive file/folder itself rather than in a list of its own.
    func setStarred(itemID: String, isStarred: Bool) {
        guard var item = item(id: itemID) else { return }
        let previousModifiedAt = item.modifiedAt
        logger.debug("setStarred: id=\(itemID, privacy: .public) isStarred=\(isStarred)")
        item.isStarred = isStarred
        applyStarred(item)
        Task {
            do {
                let updatedAt: Date
                if item.type == .folder {
                    let body = APIUpdateFolderRequest(name: nil, isStarred: isStarred)
                    let folder: APIFolderResponse = try await patch("/api/v1/drive/folders/\(itemID)", body: body)
                    updatedAt = folder.updatedAt
                } else {
                    let body = APIUpdateFileRequest(name: nil, isStarred: isStarred)
                    let file: APIFileResponse = try await patch("/api/v1/drive/files/\(itemID)", body: body)
                    updatedAt = file.updatedAt
                }
                // Starring touches `updated_at`; keep the offline cache's idea of the server
                // version in step so a metadata bump isn't mistaken for a remote content edit.
                offlineStore?.rebasePendingEdit(id: itemID,
                                                previousModifiedAt: previousModifiedAt,
                                                serverModifiedAt: updatedAt)
                logger.debug("setStarred succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("setStarred failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                item.isStarred = !isStarred
                applyStarred(item)
                self.error = error.localizedDescription
            }
        }
    }

    /// Writes an item's star flag through every collection that holds it, and adds it to (or drops
    /// it from) the Favorites listing so that list stays correct without a refetch.
    private func applyStarred(_ item: NoteItem) {
        for idx in allItems.indices where allItems[idx].id == item.id {
            allItems[idx].isStarred = item.isStarred
        }
        for idx in recentItems.indices where recentItems[idx].id == item.id {
            recentItems[idx].isStarred = item.isStarred
        }
        if item.isStarred {
            if let idx = starredItems.firstIndex(where: { $0.id == item.id }) {
                starredItems[idx] = item
            } else {
                // Most recently starred first, matching the server's `starred_at DESC` ordering.
                starredItems.insert(item, at: 0)
            }
        } else {
            starredItems.removeAll { $0.id == item.id }
        }
    }

    func createFolder(name: String, parentID: String?) {
        logger.debug("createFolder: name=\(name, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        let placeholder = NoteItem(
            id: UUID().uuidString, name: name, type: .folder,
            parentID: parentID, size: nil, modifiedAt: Date(),
            isTrashed: false, mimeType: nil
        )
        allItems.append(placeholder)
        Task {
            do {
                let body = APICreateFolderRequest(name: name, parentId: parentID)
                let created: APIFolderResponse = try await post("/api/v1/drive/folders", body: body)
                // Replace placeholder with server-assigned ID.
                if let idx = allItems.firstIndex(where: { $0.id == placeholder.id }) {
                    allItems[idx] = NoteItem(folder: created)
                }
                logger.debug("createFolder succeeded: id=\(created.id, privacy: .public)")
            } catch {
                logger.error("createFolder failed: name=\(name, privacy: .public) error=\(error, privacy: .public)")
                allItems.removeAll { $0.id == placeholder.id }
                self.error = error.localizedDescription
            }
        }
    }

    func rename(itemID: String, to newName: String) {
        guard let idx = index(of: itemID) else { return }
        let old = allItems[idx].name
        let isFolder = allItems[idx].type == .folder
        let previousModifiedAt = allItems[idx].modifiedAt
        logger.debug("rename: id=\(itemID, privacy: .public) from=\(old, privacy: .public) to=\(newName, privacy: .public)")
        allItems[idx].name = newName
        allItems[idx].modifiedAt = Date()
        Task {
            do {
                let updatedAt: Date
                if isFolder {
                    let body = APIUpdateFolderRequest(name: newName, isStarred: nil)
                    let folder: APIFolderResponse = try await patch("/api/v1/drive/folders/\(itemID)", body: body)
                    updatedAt = folder.updatedAt
                } else {
                    let body = APIUpdateFileRequest(name: newName, isStarred: nil)
                    let file: APIFileResponse = try await patch("/api/v1/drive/files/\(itemID)", body: body)
                    updatedAt = file.updatedAt
                }
                // A rename bumps `updated_at` without touching the note's content — same hazard
                // for a pending offline edit as starring does. See setStarred.
                offlineStore?.rebasePendingEdit(id: itemID,
                                                previousModifiedAt: previousModifiedAt,
                                                serverModifiedAt: updatedAt)
                logger.debug("rename succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("rename failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                if let i = index(of: itemID) { allItems[i].name = old }
                self.error = error.localizedDescription
            }
        }
    }

    /// Moves the item to Trash (first call) or permanently deletes it (if already trashed).
    func delete(itemID: String) {
        if let idx = trashItems.firstIndex(where: { $0.id == itemID }) {
            let item = trashItems.remove(at: idx)
            logger.debug("delete (permanent): id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
            Task {
                do {
                    if item.type == .folder {
                        try await deleteRequest("/api/v1/drive/trash/folders/\(itemID)")
                    } else {
                        try await deleteRequest("/api/v1/drive/trash/files/\(itemID)")
                    }
                    logger.debug("delete (permanent) succeeded: id=\(itemID, privacy: .public)")
                } catch {
                    logger.error("delete (permanent) failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                    trashItems.append(item)
                    self.error = error.localizedDescription
                }
            }
        } else if let idx = index(of: itemID) {
            let item = allItems.remove(at: idx)
            logger.debug("delete (trash): id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
            trashItems.append(NoteItem(
                id: item.id, name: item.name, type: item.type,
                parentID: item.parentID, size: item.size, modifiedAt: Date(),
                isTrashed: true, mimeType: item.mimeType, isStarred: item.isStarred
            ))
            // Trashed items are excluded from both server-side views; drop them here too rather
            // than leave a Favorites or Recents row that opens a deleted note.
            starredItems.removeAll { $0.id == itemID }
            recentItems.removeAll { $0.id == itemID }
            Task {
                do {
                    if item.type == .folder {
                        let body = APIBulkTrashRequest(fileIds: [], folderIds: [itemID])
                        let _: APIBulkResult = try await post("/api/v1/drive/bulk/trash", body: body)
                    } else {
                        let body = APIBulkTrashRequest(fileIds: [itemID], folderIds: [])
                        let _: APIBulkResult = try await post("/api/v1/drive/bulk/trash", body: body)
                    }
                    logger.debug("delete (trash) succeeded: id=\(itemID, privacy: .public)")
                } catch {
                    logger.error("delete (trash) failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                    trashItems.removeAll { $0.id == itemID }
                    allItems.append(item)
                    if item.isStarred { applyStarred(item) }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func move(itemID: String, to newParentID: String?) {
        guard let idx = index(of: itemID) else { return }
        guard !isDescendant(potentialChildID: newParentID ?? "", ofFolderID: itemID) else { return }
        let oldParent = allItems[idx].parentID
        logger.debug("move: id=\(itemID, privacy: .public) to=\(newParentID ?? "root", privacy: .public)")
        allItems[idx].parentID = newParentID
        let item = allItems[idx]
        Task {
            do {
                let body = item.type == .folder
                    ? APIBulkMoveRequest(fileIds: [], folderIds: [itemID], targetFolderId: newParentID)
                    : APIBulkMoveRequest(fileIds: [itemID], folderIds: [], targetFolderId: newParentID)
                let _: APIBulkResult = try await post("/api/v1/drive/bulk/move", body: body)
                logger.debug("move succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("move failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                if let i = index(of: itemID) { allItems[i].parentID = oldParent }
                self.error = error.localizedDescription
            }
        }
    }

    func restore(itemID: String) {
        guard let idx = trashItems.firstIndex(where: { $0.id == itemID }) else { return }
        var item = trashItems.remove(at: idx)
        logger.debug("restore: id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
        item.isTrashed = false
        allItems.append(item)
        // A restored item keeps whatever star it had when it was trashed, so Favorites gets it back.
        if item.isStarred { applyStarred(item) }
        Task {
            do {
                if item.type == .folder {
                    try await post("/api/v1/drive/trash/folders/\(itemID)/restore")
                } else {
                    try await post("/api/v1/drive/trash/files/\(itemID)/restore")
                }
                logger.debug("restore succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("restore failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                allItems.removeAll { $0.id == itemID }
                starredItems.removeAll { $0.id == itemID }
                trashItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        logger.debug("emptyTrash: removing \(self.trashItems.count) items")
        let snapshot = trashItems
        trashItems = []
        Task {
            do {
                let _: APIBulkResult = try await deleteRequest("/api/v1/drive/trash")
                logger.debug("emptyTrash succeeded")
            } catch {
                logger.error("emptyTrash failed: \(error, privacy: .public)")
                trashItems = snapshot
                self.error = error.localizedDescription
            }
        }
    }

    /// Called by NoteContentService after successfully creating a note's content, to reflect
    /// the new file in allItems.
    func noteWasCreated(_ item: NoteItem) {
        allItems.append(item)
        logger.debug("noteWasCreated: id=\(item.id, privacy: .public) name=\(item.name, privacy: .public)")
    }

    /// Called by the editor after a successful autosave, to keep the browser's size/date in sync.
    func noteContentWasSaved(itemID: String, size: Int64, modifiedAt: Date) {
        if let idx = index(of: itemID) {
            allItems[idx].size = size
            allItems[idx].modifiedAt = modifiedAt
        }
        // Keep the Epic 12 listings honest about a note the user just edited — Recents is ordered
        // by exactly this timestamp.
        for idx in recentItems.indices where recentItems[idx].id == itemID {
            recentItems[idx].size = size
            recentItems[idx].modifiedAt = modifiedAt
        }
        for idx in starredItems.indices where starredItems[idx].id == itemID {
            starredItems[idx].size = size
            starredItems[idx].modifiedAt = modifiedAt
        }
    }

    // MARK: - Ancestry Check

    func isDescendant(potentialChildID: String, ofFolderID folderID: String) -> Bool {
        var currentID: String? = potentialChildID
        while let id = currentID {
            if id == folderID { return true }
            currentID = allItems.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    // MARK: - Private Helpers

    private func index(of itemID: String) -> Int? {
        allItems.firstIndex(where: { $0.id == itemID })
    }

    // MARK: - HTTP

    /// Builds a URLRequest without an Authorization header; `perform` injects it after refresh.
    private func request(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw NotesDriveError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    @discardableResult
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let req = try request(method: "GET", path: path)
        return try await perform(req)
    }

    @discardableResult
    private func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let req = try request(method: "POST", path: path, body: body)
        return try await perform(req)
    }

    private func post(_ path: String) async throws {
        let req = try request(method: "POST", path: path)
        try await performVoid(req)
    }

    @discardableResult
    private func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let req = try request(method: "PATCH", path: path, body: body)
        return try await perform(req)
    }

    @discardableResult
    private func deleteRequest<T: Decodable>(_ path: String) async throws -> T {
        let req = try request(method: "DELETE", path: path)
        return try await perform(req)
    }

    private func deleteRequest(_ path: String) async throws {
        let req = try request(method: "DELETE", path: path)
        try await performVoid(req)
    }

    /// Refreshes the token if needed, injects it, executes the request, and decodes the response.
    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let req = try await authorized(req)
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.absoluteString ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.absoluteString ?? "?", privacy: .public) \(error, privacy: .public)")
            throw NotesDriveError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NotesDriveError.serverError(statusCode: 0)
        }
        let rawBody = String(data: data, encoding: .utf8) ?? "(binary, \(data.count) bytes)"
        logger.debug("<-- \(http.statusCode) \(req.url?.absoluteString ?? "?", privacy: .public) body=\(rawBody, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            logger.error("server error \(http.statusCode) \(req.url?.absoluteString ?? "?", privacy: .public): \(rawBody, privacy: .public)")
            throw NotesDriveError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode error \(req.url?.absoluteString ?? "?", privacy: .public): \(error, privacy: .public) body=\(rawBody, privacy: .public)")
            throw NotesDriveError.decodingError(underlying: error)
        }
    }

    /// Same as `perform` but for endpoints that return no body.
    private func performVoid(_ req: URLRequest) async throws {
        let req = try await authorized(req)
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw NotesDriveError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NotesDriveError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw NotesDriveError.serverError(statusCode: http.statusCode)
        }
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw NotesDriveError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - NoteItem convenience initialisers

private extension NoteItem {
    init(folder: APIFolderResponse) {
        self.init(
            id: folder.id,
            name: folder.name,
            type: .folder,
            parentID: folder.parentId,
            size: nil,
            modifiedAt: folder.updatedAt,
            isTrashed: false,
            mimeType: nil,
            isStarred: folder.isStarred
        )
    }

    init(file: APIFileResponse) {
        self.init(
            id: file.id,
            name: file.name,
            type: .file,
            parentID: file.folderId,
            size: file.sizeBytes,
            modifiedAt: file.updatedAt,
            isTrashed: false,
            mimeType: file.mimeType,
            isStarred: file.isStarred
        )
    }

    init(trashFolder: APITrashFolderItem) {
        self.init(
            id: trashFolder.id,
            name: trashFolder.name,
            type: .folder,
            parentID: nil,
            size: nil,
            modifiedAt: trashFolder.deletedAt,
            isTrashed: true,
            mimeType: nil
        )
    }

    init(trashFile: APITrashFileItem) {
        self.init(
            id: trashFile.id,
            name: trashFile.name,
            type: .file,
            parentID: nil,
            size: trashFile.sizeBytes,
            modifiedAt: trashFile.deletedAt,
            isTrashed: true,
            mimeType: trashFile.mimeType
        )
    }
}

// MARK: - API Response / Request Models

private struct APIFolderContentsResponse: Decodable {
    let files: [APIFileResponse]
    let folders: [APIFolderResponse]
}

private struct APIFolderResponse: Decodable {
    let id: String
    let name: String
    let parentId: String?
    let updatedAt: Date
    let isStarred: Bool
}

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
    let isStarred: Bool
}

private struct APITrashContentsResponse: Decodable {
    let files: [APITrashFileItem]
    let folders: [APITrashFolderItem]
}

private struct APITrashFileItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let deletedAt: Date
}

private struct APITrashFolderItem: Decodable {
    let id: String
    let name: String
    let deletedAt: Date
}

private struct APICreateFolderRequest: Encodable {
    let name: String
    let parentId: String?
}

private struct APIUpdateFolderRequest: Encodable {
    let name: String?
    let isStarred: Bool?
}

private struct APIUpdateFileRequest: Encodable {
    let name: String?
    let isStarred: Bool?
}

private struct APIBulkTrashRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
}

private struct APIBulkMoveRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
    let targetFolderId: String?
}

private struct APIBulkResult: Decodable {
    let affected: Int
}
