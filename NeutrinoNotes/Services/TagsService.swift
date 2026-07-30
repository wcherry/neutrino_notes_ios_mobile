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

    /// Replaces a file's tags wholesale — the same shape as the server's `PUT`, so a picker can
    /// send one request no matter how many tags were added or removed.
    func setTags(_ tagIDs: [String], for fileID: String) async throws {
        logger.debug("setTags: file=\(fileID, privacy: .public) count=\(tagIDs.count)")
        let updated: [NoteTag] = try await put("/api/v1/drive/files/\(fileID)/tags",
                                               body: APISetFileTagsRequest(tagIds: tagIDs))
        tagsByFileID[fileID] = updated.sorted(by: NoteTag.byName)
    }

    // MARK: - Notes by Tag

    /// The notes carrying a tag. The endpoint returns every kind of file, so the response is
    /// reduced to Markdown notes with the same predicate the folder listing uses.
    func notes(withTag tagID: String) async throws -> [NoteItem] {
        logger.debug("notes(withTag:): tag=\(tagID, privacy: .public)")
        let response: APIListTaggedFilesResponse = try await get("/api/v1/drive/tags/\(tagID)/files")
        let notes = response.files.map { NoteItem(taggedFile: $0) }.filter(NoteItem.isVisibleInNotes)
        logger.debug("notes(withTag:): \(notes.count) of \(response.files.count) tagged files are notes")
        return notes
    }

    // MARK: - Private Helpers

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

    private func put<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(try request(method: "PUT", path: path, body: body))
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

private extension NoteItem {
    /// `GET /drive/tags/{id}/files` returns a trimmed file summary — no star flag, so a note
    /// reached through a tag shows no star until it is seen in a listing that carries one.
    init(taggedFile: APITaggedFileResponse) {
        self.init(
            id: taggedFile.id,
            name: taggedFile.name,
            type: .file,
            parentID: taggedFile.folderId,
            size: taggedFile.sizeBytes,
            modifiedAt: taggedFile.updatedAt,
            isTrashed: false,
            mimeType: taggedFile.mimeType
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

private struct APISetFileTagsRequest: Encodable {
    let tagIds: [String]
}

private struct APIListTaggedFilesResponse: Decodable {
    let files: [APITaggedFileResponse]
    let total: Int
}

private struct APITaggedFileResponse: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let folderId: String?
    let updatedAt: Date
}
