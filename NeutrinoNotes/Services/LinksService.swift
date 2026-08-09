import Foundation
import os.log

// MARK: - LinksError

enum LinksError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - LinksService

/// Reads and writes Drive's cross-file link graph (`src/links/`).
///
/// The graph is generic — notes, docs and sheets all share one table — and this app is one of its
/// clients, not its owner. Two calls, both keyed by file id:
///
/// * `GET  /api/v1/links/{id}/backlinks` — what links *to* this note. Needs read access.
/// * `PATCH /api/v1/links/{id}` — the titles this note links *out* to. Needs `owner` or `editor`,
///   and is answered with the note's backlinks, not with what was just sent.
///
/// The titles travel in the clear. They are text out of an end-to-end-encrypted body, so this is a
/// deliberate, narrow disclosure: for a title that resolves, the resulting edge and both file names
/// are already server-side, and for one that doesn't, the server sees a phrase and stores nothing.
/// The alternative — a device-local graph — would not be visible to the web app, which is where
/// most of these links are written. `FeatureFlags.noteLinks` turns the whole thing off.
@MainActor
final class LinksService: ObservableObject {

    // MARK: - Published State

    /// Backlinks by file id, for whatever the editor last looked at.
    @Published private(set) var backlinksByFileID: [String: [FileLink]] = [:]

    // MARK: - Dependencies

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    // MARK: - Test Seeding

    #if DEBUG
    convenience init(backlinks: [String: [FileLink]]) {
        self.init()
        self.backlinksByFileID = backlinks
    }
    #endif

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "LinksService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    /// The links payload is camelCase on both sides (`#[serde(rename_all = "camelCase")]`), so no
    /// key conversion — `convertFromSnakeCase` would leave `fileType` alone anyway, but saying so
    /// here is cheaper than making the next reader check.
    private static let decoder = JSONDecoder()

    // MARK: - Reads

    func backlinks(for fileID: String) -> [FileLink] {
        backlinksByFileID[fileID] ?? []
    }

    /// Fetches what links to `fileID`. Read access is enough, so this works on a shared note.
    @discardableResult
    func loadBacklinks(for fileID: String) async throws -> [FileLink] {
        let response: BacklinksResponse = try await perform(request(method: "GET",
                                                                    path: "/api/v1/links/\(fileID)/backlinks"))
        backlinksByFileID[fileID] = response.backlinks
        return response.backlinks
    }

    // MARK: - Writes

    /// Replaces the set of links going *out* of `fileID` with whatever `titles` resolves to.
    ///
    /// Titles that match nothing, match a trashed file, or match a file the caller can't read are
    /// dropped server-side without an error — that is the normal case for a link written before its
    /// target exists, not a failure. The server diffs against the stored set, so sending the same
    /// titles twice is a no-op rather than a rewrite.
    @discardableResult
    func updateLinks(fileID: String, titles: [String]) async throws -> [FileLink] {
        var req = try request(method: "PATCH", path: "/api/v1/links/\(fileID)")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(UpdateLinksRequest(linkedTitles: titles))

        let response: BacklinksResponse = try await perform(req)
        backlinksByFileID[fileID] = response.backlinks
        return response.backlinks
    }

    /// The editor's version of [updateLinks]: never throws, never reports.
    ///
    /// A note's content is saved by the time this runs. Turning a failed link update into a visible
    /// "save failed" would be a lie about the thing the user actually cares about, and the next save
    /// re-sends the full set anyway, so there is nothing to retry by hand.
    ///
    /// Skips the request when this note's titles haven't changed since the last one. Autosave fires
    /// after ~1.5s of quiet, and most of those saves change prose rather than links; each PATCH
    /// makes the server list every file the caller can read to resolve titles, so re-sending an
    /// unchanged set is real work for a guaranteed no-op. Pass `force` when something *other* than
    /// the text changed what the titles resolve to — creating the note one of them names, say.
    func updateLinksIgnoringFailure(fileID: String, in text: String, force: Bool = false) async {
        guard FeatureFlags.noteLinks else { return }
        let titles = WikiLink.requestTitles(in: text)
        if !force, lastSentTitles[fileID] == titles { return }
        do {
            try await updateLinks(fileID: fileID, titles: titles)
            lastSentTitles[fileID] = titles
        } catch {
            // Not recorded as sent: the next save should try again rather than assume this stuck.
            logger.error("updateLinks failed for id=\(fileID, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Drops a note's cached backlinks — after it is deleted, or when signing out.
    func forget(fileID: String) {
        backlinksByFileID[fileID] = nil
        lastSentTitles[fileID] = nil
    }

    func forgetAll() {
        backlinksByFileID = [:]
        lastSentTitles = [:]
    }

    /// The last title set successfully sent for each file, so an unchanged set isn't re-sent.
    private var lastSentTitles: [String: [String]] = [:]

    // MARK: - HTTP

    private func request(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw LinksError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let req = try await authorized(req)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LinksError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LinksError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw LinksError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw LinksError.decodingError(underlying: error)
        }
    }

    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw LinksError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - Request Models

/// `PATCH /api/v1/links/{fileId}`.
///
/// `linkedIds` and `linkedRanges` exist in the server's DTO and answer 400 — they are reserved for
/// a later phase, so they are deliberately absent here rather than sent as null.
private struct UpdateLinksRequest: Encodable {
    let linkedTitles: [String]
}
