import Foundation
import Sodium
import os.log

// MARK: - VersionHistoryError

enum VersionHistoryError: LocalizedError {
    case notAuthenticated
    case noContentService
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .noContentService:       return "Version history is unavailable right now."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - VersionHistoryService

// Reads and writes a note's version history through Drive's existing versioning APIs — the
// Notes app adds no versioning of its own.
//
// Every snapshot is stored as the ciphertext that was uploaded at the time, and a file's DEK
// never rotates, so the session DEK the editor already holds decrypts every version of that
// note. All crypto is delegated to NoteContentService, the same way OfflineStore does it;
// this type owns only the HTTP.
//
// One consequence of the server's design is worth stating: autosave deliberately does *not*
// create a snapshot (only the initial upload and an explicit save do), so a note accumulates
// history only when the user saves a named version.
@MainActor
final class VersionHistoryService: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    /// Set once at app launch — supplies the encrypt/decrypt primitives.
    weak var noteContentService: NoteContentService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "VersionHistoryService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - List

    /// All snapshots for a note, newest first (the server's default ordering is by version
    /// number descending).
    func listVersions(fileID: String) async throws -> [NoteVersion] {
        logger.debug("listVersions: id=\(fileID, privacy: .public)")
        let data = try await get("/api/v1/drive/files/\(fileID)/versions")
        do {
            let response = try NoteVersion.decoder.decode(APIListVersionsResponse.self, from: data)
            logger.debug("listVersions: id=\(fileID, privacy: .public) returned \(response.versions.count) of \(response.total)")
            return response.versions
        } catch {
            logger.error("listVersions decode failed: \(error, privacy: .public)")
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - Read a snapshot

    /// Downloads a snapshot and decrypts it with the note's DEK.
    func versionText(fileID: String, versionID: String, dek: Bytes) async throws -> String {
        logger.debug("versionText: id=\(fileID, privacy: .public) version=\(versionID, privacy: .public)")
        guard let content = noteContentService else { throw VersionHistoryError.noContentService }
        let ciphertext = try await get("/api/v1/drive/files/\(fileID)/versions/\(versionID)/download")
        let text = try content.decrypt(data: ciphertext, dek: dek)
        logger.debug("versionText: decrypted \(text.utf8.count) bytes")
        return text
    }

    // MARK: - Save a named version

    /// Encrypts `text` with the note's DEK and saves it as a named snapshot. The server also
    /// makes this the note's current content, so this is a save-and-snapshot, not a
    /// snapshot-only — the same behavior as the web app's explicit save.
    func saveVersion(_ text: String, for item: NoteItem, dek: Bytes, label: String?) async throws -> NoteVersion {
        logger.debug("saveVersion: id=\(item.id, privacy: .public) labeled=\(label != nil)")
        guard let content = noteContentService else { throw VersionHistoryError.noContentService }

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let ciphertext = try content.encrypt(text: text, dek: dek, xcss: xcss)

        var form = MultipartFormBody()
        form.appendField(name: "label", value: label)
        form.appendFile(
            name: "file",
            fileName: item.name,
            mimeType: item.mimeType ?? NoteItem.markdownMIME,
            data: ciphertext
        )

        var request = try self.request(method: "POST", path: "/api/v1/drive/files/\(item.id)/versions")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await perform(request, body: form.finalized())
        do {
            let version = try NoteVersion.decoder.decode(NoteVersion.self, from: data)
            logger.debug("saveVersion succeeded: v\(version.versionNumber)")
            return version
        } catch {
            logger.error("saveVersion decode failed: \(error, privacy: .public)")
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - Restore

    /// Makes a snapshot the note's current content. The server snapshots the pre-restore
    /// content first, so restoring is itself undoable from the history list.
    ///
    /// Returns the note's new size and modification date so callers can reflect them without
    /// a second round-trip.
    @discardableResult
    func restore(versionID: String, fileID: String) async throws -> (sizeBytes: Int64, modifiedAt: Date) {
        logger.debug("restore: id=\(fileID, privacy: .public) version=\(versionID, privacy: .public)")
        let request = try self.request(method: "POST", path: "/api/v1/drive/files/\(fileID)/versions/\(versionID)/restore")
        let data = try await perform(request, body: nil)
        do {
            let file = try NoteVersion.decoder.decode(APIFileMetadataResponse.self, from: data)
            logger.debug("restore succeeded: id=\(fileID, privacy: .public)")
            return (file.sizeBytes, file.updatedAt)
        } catch {
            logger.error("restore decode failed: \(error, privacy: .public)")
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - HTTP

    private func request(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    private func get(_ path: String) async throws -> Data {
        try await perform(try request(method: "GET", path: path), body: nil)
    }

    /// Refreshes the token if needed, injects it, and returns the raw response body. Callers
    /// decode it, or use it as-is where the body is ciphertext rather than JSON.
    private func perform(_ req: URLRequest, body: Data?) async throws -> Data {
        var req = req
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("perform: no access token in keychain — user must re-login")
            throw VersionHistoryError.notAuthenticated
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await URLSession.shared.upload(for: req, from: body)
            } else {
                (data, response) = try await URLSession.shared.data(for: req)
            }
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw VersionHistoryError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public) (\(data.count) bytes)")
        guard (200...299).contains(http.statusCode) else {
            throw VersionHistoryError.serverError(statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - API Response Models

private struct APIListVersionsResponse: Decodable {
    let versions: [NoteVersion]
    let total: Int
}

/// The subset of Drive's file metadata the restore endpoint returns that this service needs.
private struct APIFileMetadataResponse: Decodable {
    let sizeBytes: Int64
    let updatedAt: Date
}
