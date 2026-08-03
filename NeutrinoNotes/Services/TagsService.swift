import Foundation
import os.log

// MARK: - TagsError

enum TagsError: LocalizedError {
    case notAuthenticated
    case duplicateName(String)
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "You are not signed in."
        case .duplicateName(let name): return "A tag named \u{201C}\(name)\u{201D} already exists."
        case .networkError:            return "A network error occurred. Please check your connection."
        case .serverError(let code):   return "Server error (\(code))."
        case .decodingError(let err):  return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - TagsService

// Reads and writes note tags through Drive's existing tag APIs — the Notes app stores no tags of
// its own.
//
// A tag belongs to the user and is attached to any number of files, so this service keeps two
// caches: every tag the user owns, and the tags of the individual files that have been looked at.
// There is no bulk "tags for these files" endpoint, so per-file tags are fetched one file at a
// time and only where a single request is natural (the editor, the tag picker) — never per row of
// a listing.
//
// Worth knowing: a tag's *name* is stored on the server in the clear, exactly like a file's name.
// Note bodies remain end-to-end encrypted; tags are readable metadata.
@MainActor
final class TagsService: ObservableObject {

    // MARK: - Published State

    /// Every tag the user owns, sorted case-insensitively by name.
    @Published private(set) var tags: [NoteTag] = []
    /// Cached per-file tags, keyed by Drive file id.
    @Published private(set) var tagsByFileID: [String: [NoteTag]] = [:]

    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Test Seeding

    #if DEBUG
    /// Seed state for unit tests — bypasses the network entirely.
    convenience init(tags: [NoteTag] = [], tagsByFileID: [String: [NoteTag]] = [:]) {
        self.init()
        self.tags = tags.sorted(by: NoteTag.byName)
        self.tagsByFileID = tagsByFileID
    }
    #endif

    // MARK: - Dependencies

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    // MARK: - Private

    /// The server clamps `limit` to 200 and defaults to 50, so ask for the largest page it will
    /// give and let `notes(withTag:)` walk the rest.
    private static let taggedFilesPageSize = 200

    private static let decoder = NoteTag.decoder

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "TagsService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Queries

    /// Cached tags for a file. Empty until `loadTags(for:)` has run for that file.
    func tags(for fileID: String) -> [NoteTag] {
        tagsByFileID[fileID] ?? []
    }

    // MARK: - Tag List

    func loadTags() async {
        logger.debug("loadTags")
        isLoading = true
        error = nil
        do {
            let response: APIListTagsResponse = try await get("/api/v1/drive/tags")
            tags = response.tags.sorted(by: NoteTag.byName)
            logger.debug("loadTags: \(self.tags.count) tag(s)")
        } catch {
            logger.error("loadTags failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Tag CRUD

    /// Creates a tag and returns it. A 409 means the name is taken, which callers surface as a
    /// validation message rather than a server error.
    @discardableResult
    func createTag(named name: String) async throws -> NoteTag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("createTag: name=\(trimmed, privacy: .public)")
        do {
            let tag: NoteTag = try await post("/api/v1/drive/tags", body: APICreateTagRequest(name: trimmed))
            tags.append(tag)
            tags.sort(by: NoteTag.byName)
            return tag
        } catch TagsError.serverError(statusCode: 409) {
            logger.error("createTag rejected as duplicate: name=\(trimmed, privacy: .public)")
            throw TagsError.duplicateName(trimmed)
        }
    }

    /// Renames a tag optimistically, rolling every cache back together if the server refuses.
    func renameTag(_ tag: NoteTag, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else { return }
        logger.debug("renameTag: id=\(tag.id, privacy: .public) to=\(trimmed, privacy: .public)")
        applyRename(tagID: tag.id, to: trimmed)
        Task {
            do {
                let _: NoteTag = try await patch("/api/v1/drive/tags/\(tag.id)",
                                                 body: APIUpdateTagRequest(name: trimmed))
                logger.debug("renameTag succeeded: id=\(tag.id, privacy: .public)")
            } catch {
                logger.error("renameTag failed: id=\(tag.id, privacy: .public) error=\(error, privacy: .public)")
                applyRename(tagID: tag.id, to: tag.name)
                self.error = renameErrorMessage(for: error, name: trimmed)
            }
        }
    }

    /// Deletes a tag optimistically. The server also detaches it from every file, so the per-file
    /// caches drop it too.
    func deleteTag(_ tag: NoteTag) {
        logger.debug("deleteTag: id=\(tag.id, privacy: .public) name=\(tag.name, privacy: .public)")
        let previousByFile = tagsByFileID
        tags.removeAll { $0.id == tag.id }
        for (fileID, fileTags) in tagsByFileID {
            tagsByFileID[fileID] = fileTags.filter { $0.id != tag.id }
        }
        Task {
            do {
                try await deleteRequest("/api/v1/drive/tags/\(tag.id)")
                logger.debug("deleteTag succeeded: id=\(tag.id, privacy: .public)")
            } catch {
                logger.error("deleteTag failed: id=\(tag.id, privacy: .public) error=\(error, privacy: .public)")
                tags.append(tag)
                tags.sort(by: NoteTag.byName)
                tagsByFileID = previousByFile
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - File Tags

    /// Fetches (and caches) the tags attached to one file.
    @discardableResult
    func loadTags(for fileID: String) async throws -> [NoteTag] {
        logger.debug("loadTags(for:): file=\(fileID, privacy: .public)")
        let fileTags: [NoteTag] = try await get("/api/v1/drive/files/\(fileID)/tags")
        let sorted = fileTags.sorted(by: NoteTag.byName)
        tagsByFileID[fileID] = sorted
        return sorted
    }

    /// Attaches a tag to a file. The server's insert is idempotent, so re-adding an attached tag
    /// is a no-op rather than an error.
    func addTag(_ tag: NoteTag, to fileID: String) async throws {
        logger.debug("addTag: tag=\(tag.id, privacy: .public) file=\(fileID, privacy: .public)")
        try await postWithoutResponse("/api/v1/drive/files/\(fileID)/tags/\(tag.id)")
        var fileTags = tagsByFileID[fileID] ?? []
        guard !fileTags.contains(where: { $0.id == tag.id }) else { return }
        fileTags.append(tag)
        tagsByFileID[fileID] = fileTags.sorted(by: NoteTag.byName)
        adjustFileCount(ofTag: tag.id, by: 1)
    }

    /// Detaches a tag from a file. The tag itself is untouched — it stays on every other note and
    /// in the tag list.
    func removeTag(_ tag: NoteTag, from fileID: String) async throws {
        logger.debug("removeTag: tag=\(tag.id, privacy: .public) file=\(fileID, privacy: .public)")
        try await deleteRequest("/api/v1/drive/files/\(fileID)/tags/\(tag.id)")
        guard let fileTags = tagsByFileID[fileID], fileTags.contains(where: { $0.id == tag.id }) else { return }
        tagsByFileID[fileID] = fileTags.filter { $0.id != tag.id }
        adjustFileCount(ofTag: tag.id, by: -1)
    }

    /// Writes a picker's selection back as the difference from what the file already carries.
    ///
    /// Deliberately not the server's replace-all `PUT`: per-tag writes are idempotent, so a tag
    /// attached from another device between load and save survives instead of being wiped, and one
    /// rejected tag costs only that tag rather than the whole selection. Every change is attempted
    /// even if an earlier one fails; the first failure is rethrown once the rest are done, so the
    /// caches match what the server actually accepted.
    func applyTags(_ selectedIDs: Set<String>, to fileID: String) async throws {
        let current = Set((tagsByFileID[fileID] ?? []).map(\.id))
        let diff = Self.tagDiff(current: current, selected: selectedIDs)
        logger.debug("applyTags: file=\(fileID, privacy: .public) +\(diff.added.count) -\(diff.removed.count)")

        var firstError: Error?
        for tag in diff.added.compactMap(tag(withID:)) {
            do { try await addTag(tag, to: fileID) } catch { firstError = firstError ?? error }
        }
        for tag in diff.removed.compactMap(tag(withID:)) {
            do { try await removeTag(tag, from: fileID) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// The add/remove work a selection implies. Pure and total, so the picker's save behaviour is
    /// testable without a server.
    static func tagDiff(current: Set<String>,
                        selected: Set<String>) -> (added: [String], removed: [String]) {
        (added: selected.subtracting(current).sorted(),
         removed: current.subtracting(selected).sorted())
    }

    // MARK: - Notes by Tag

    /// The notes carrying a tag. `type=note` narrows the listing server-side, so a tag applied to
    /// PDFs and images alike still pages through notes only.
    ///
    /// Paged: the server caps a page at 200 and defaults to 50, so a single request would silently
    /// truncate a well-used tag. `total` counts every accessible note before pagination — the
    /// `type` filter is applied before it — which is what ends the loop.
    func notes(withTag tagID: String) async throws -> [NoteItem] {
        logger.debug("notes(withTag:): tag=\(tagID, privacy: .public)")
        var files: [APITaggedFileResponse] = []
        var offset = 0
        while true {
            let path = "/api/v1/drive/tags/\(tagID)/files?limit=\(Self.taggedFilesPageSize)&offset=\(offset)&type=note"
            let page: APIListTaggedFilesResponse = try await get(path)
            files.append(contentsOf: page.files)
            offset += page.files.count
            // The empty-page guard is what makes this terminate if `total` and the page ever
            // disagree — a tag whose files change mid-listing, say.
            if page.files.isEmpty || files.count >= page.total { break }
        }
        let notes = files.map { NoteItem(taggedFile: $0) }
        logger.debug("notes(withTag:): \(notes.count) tagged notes")
        return notes
    }

    // MARK: - Private Helpers

    private func tag(withID id: String) -> NoteTag? {
        tags.first { $0.id == id }
    }

    /// Keeps a tag's file count honest between refreshes: attaching or detaching it on a note
    /// changes the number the tag list shows, and re-fetching every tag for one toggle is wasteful.
    private func adjustFileCount(ofTag tagID: String, by delta: Int) {
        guard let idx = tags.firstIndex(where: { $0.id == tagID }) else { return }
        tags[idx].fileCount = max(0, tags[idx].fileCount + delta)
    }

    private func applyRename(tagID: String, to newName: String) {
        if let idx = tags.firstIndex(where: { $0.id == tagID }) {
            tags[idx].name = newName
            tags.sort(by: NoteTag.byName)
        }
        for (fileID, fileTags) in tagsByFileID {
            guard fileTags.contains(where: { $0.id == tagID }) else { continue }
            var updated = fileTags
            for idx in updated.indices where updated[idx].id == tagID {
                updated[idx].name = newName
            }
            tagsByFileID[fileID] = updated.sorted(by: NoteTag.byName)
        }
    }

    private func renameErrorMessage(for error: Error, name: String) -> String {
        if case TagsError.serverError(statusCode: 409) = error {
            return TagsError.duplicateName(name).localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - HTTP

    /// Builds a URLRequest without an Authorization header; `perform` injects it after refresh.
    private func request(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw TagsError.serverError(statusCode: 0)
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

    /// The file-tag attach endpoint answers 204 — a POST with nothing to decode.
    private func postWithoutResponse(_ path: String) async throws {
        _ = try await execute(try await authorized(try request(method: "POST", path: path)))
    }

    private func deleteRequest(_ path: String) async throws {
        // The tag endpoints that mutate without returning a body answer 204 — nothing to decode.
        _ = try await execute(try await authorized(try request(method: "DELETE", path: path)))
    }

    /// Refreshes the token if needed, injects it, executes the request, and decodes the response.
    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data = try await execute(try await authorized(req))
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public)")
            throw TagsError.decodingError(underlying: error)
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
            throw TagsError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TagsError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public) (\(data.count) bytes)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw TagsError.serverError(statusCode: http.statusCode)
        }
        return data
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw TagsError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - NoteItem convenience initialiser

extension NoteItem {
    /// `GET /drive/tags/{id}/files` mirrors the filesystem listing field-for-field, star flag
    /// included, so a note reached through a tag renders exactly as it does in the browser.
    /// The endpoint excludes trashed files, hence the constant.
    init(taggedFile: APITaggedFileResponse) {
        self.init(
            id: taggedFile.id,
            name: taggedFile.name,
            type: .file,
            parentID: taggedFile.folderId,
            size: taggedFile.sizeBytes,
            modifiedAt: taggedFile.updatedAt,
            isTrashed: false,
            mimeType: taggedFile.mimeType,
            isStarred: taggedFile.isStarred ?? false
        )
    }
}

// MARK: - API Response / Request Models

private struct APIListTagsResponse: Decodable {
    let tags: [NoteTag]
    let total: Int
}

private struct APICreateTagRequest: Encodable {
    let name: String
}

private struct APIUpdateTagRequest: Encodable {
    let name: String
}

struct APIListTaggedFilesResponse: Decodable {
    let files: [APITaggedFileResponse]
    /// Every accessible file carrying the tag, before pagination — what `notes(withTag:)` pages
    /// against. The response also echoes `limit`/`offset`, which this client already knows.
    let total: Int
}

struct APITaggedFileResponse: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let folderId: String?
    /// Optional only to tolerate a server predating the field, which used to return a trimmed file
    /// summary; a note then renders unstarred rather than the listing failing to decode.
    let isStarred: Bool?
    let updatedAt: Date
}
