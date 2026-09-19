import Foundation
import Sodium
import CryptoKit
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - NoteContentError

enum NoteContentError: LocalizedError {
    case noEncryptionKey
    case encryptionFailed
    case decryptionFailed
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:        return "No encryption key found. Please import a key before creating or opening notes."
        case .encryptionFailed:       return "Failed to encrypt the note."
        case .decryptionFailed:       return "Failed to decrypt the note."
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - NoteContentService

// Encrypts, uploads, downloads, and decrypts the Markdown body of a note. Mirrors the E2EE
// protocol used by Neutrino Drive's file upload/download/autosave endpoints exactly (XChaCha20-
// Poly1305 secretstream for content, crypto_box_seal for the per-file key), so notes created here
// are readable by the web app and vice versa. NotesDriveService handles metadata only (name,
// folder, trash); this service handles the encrypted body.
@MainActor
final class NoteContentService: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch by NeutrinoNotesApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "NoteContentService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    private static let decoder: JSONDecoder = DriveDate.makeDecoder(convertFromSnakeCase: true)

    // MARK: - Create

    /// Creates a new, empty Markdown note in Drive and returns the resulting NoteItem.
    func createNote(name: String, parentID: String?) async throws -> NoteItem {
        logger.error("createNote: name=\(name, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let dek: Bytes = xcss.key()
        let encryptedContent = try encrypt(text: "", dek: dek, xcss: xcss)
        let encryptedMetadata = try encryptMetadata(name: name, mimeType: NoteItem.markdownMIME, dek: dek, xcss: xcss)
        let sealedFileKey = try sealDEK(dek)
        logger.debug("createNote: encryptedContent=\(encryptedContent.count) bytes sha256=\(Self.fingerprint(encryptedContent), privacy: .public)")

        let form = buildUploadBody(
            encryptedData: encryptedContent, fileName: name, mimeType: NoteItem.markdownMIME,
            parentFolderID: parentID, encryptedMetadata: encryptedMetadata
        )

        guard let url = URL(string: baseURL + "/api/v1/drive/files/upload") else {
            throw NoteContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response)
        let created: APIFileResponse
        do {
            created = try Self.decoder.decode(APIFileResponse.self, from: data)
        } catch {
            throw NoteContentError.decodingError(underlying: error)
        }

        try await storeFileKey(fileID: created.id,
                               encryptedFileKey: sealedFileKey.sealed,
                               keyVersion: sealedFileKey.keyVersion,
                               token: token)
        logger.error("createNote succeeded: id=\(created.id, privacy: .public)")

        return NoteItem(
            id: created.id, name: created.name, type: .file, parentID: created.folderId,
            size: created.sizeBytes, modifiedAt: created.updatedAt, isTrashed: false,
            mimeType: created.mimeType
        )
    }

    // MARK: - Load

    /// Downloads and decrypts a note's content. Returns the plaintext and the DEK — the caller
    /// should hold onto the DEK for the editing session so subsequent autosaves don't need to
    /// re-fetch and re-unseal it.
    func loadContent(for item: NoteItem) async throws -> (text: String, dek: Bytes) {
        logger.error("loadContent: id=\(item.id, privacy: .public)")
        let token = try await authorizedToken()

        await debugCompareRegisteredPublicKey(token: token)

        let sealedFileKey = try await fetchSealedDEK(fileID: item.id, token: token)
        logger.debug("loadContent: sealedFileKey is \(sealedFileKey.sealed.count) chars, v\(sealedFileKey.keyVersion)")

        let dek: Bytes
        do {
            dek = try unsealDEK(sealedFileKey.sealed, keyVersion: sealedFileKey.keyVersion)
            logger.debug("loadContent: unsealDEK succeeded")
        } catch {
            logger.error("loadContent: unsealDEK FAILED for id=\(item.id, privacy: .public): \(error, privacy: .public)")
            throw error
        }

        let encryptedData = try await fetchEncryptedContent(fileID: item.id, token: token)
        logger.error("loadContent: fetched \(encryptedData.count) encrypted bytes sha256=\(Self.fingerprint(encryptedData), privacy: .public)")

        do {
            let text = try decrypt(data: encryptedData, dek: dek)
            logger.error("loadContent succeeded: id=\(item.id, privacy: .public) (\(text.utf8.count) bytes)")
            return (text, dek)
        } catch {
            logger.error("loadContent: content decrypt FAILED for id=\(item.id, privacy: .public): \(error, privacy: .public) rawBytes=\(encryptedData.count)")
            throw error
        }
    }

    // MARK: - Save (autosave)

    /// Encrypts `text` with the note's existing DEK and PUTs it to the autosave endpoint.
    /// Returns the server's updated `updatedAt` so the caller can reflect it in NotesDriveService.
    func saveContent(_ text: String, for item: NoteItem, dek: Bytes) async throws -> Date {
        logger.error("saveContent: id=\(item.id, privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let encryptedContent = try encrypt(text: text, dek: dek, xcss: xcss)
        logger.debug("saveContent: plaintext=\(text.utf8.count) bytes encryptedContent=\(encryptedContent.count) bytes sha256=\(Self.fingerprint(encryptedContent), privacy: .public)")

        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(item.id)/autosave") else {
            throw NoteContentError.serverError(statusCode: 0)
        }

        // The autosave endpoint expects the same multipart/form-data "file" part as create —
        // sending the raw bytes as application/octet-stream trips actix-multipart's
        // ContentTypeIncompatible check. No encrypted_metadata or folder_id here; those only
        // apply on create.
        let form = buildUploadBody(
            encryptedData: encryptedContent, fileName: item.name,
            mimeType: item.mimeType ?? NoteItem.markdownMIME,
            parentFolderID: nil, encryptedMetadata: nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response)
        do {
            let updated = try Self.decoder.decode(APIFileResponse.self, from: data)
            logger.error("saveContent succeeded: id=\(item.id, privacy: .public)")
            return updated.updatedAt
        } catch {
            throw NoteContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Offline Support

    /// Downloads a note's still-encrypted body together with its sealed DEK, without decrypting.
    /// Used by OfflineStore so the cache-at-rest blob is byte-identical to the server's.
    func downloadEncrypted(
        for item: NoteItem
    ) async throws -> (ciphertext: Data, sealedDEK: (sealed: String, keyVersion: Int)) {
        logger.debug("downloadEncrypted: id=\(item.id, privacy: .public)")
        let token = try await authorizedToken()
        let sealedDEK = try await fetchSealedDEK(fileID: item.id, token: token)
        let ciphertext = try await fetchEncryptedContent(fileID: item.id, token: token)
        logger.debug("downloadEncrypted: id=\(item.id, privacy: .public) \(ciphertext.count) encrypted bytes")
        return (ciphertext, sealedDEK)
    }

    /// The server's current `updatedAt` for a file, used for conflict detection.
    ///
    /// Returns nil if the file is no longer reachable server-side — deleted, trashed, or access
    /// revoked — which `SyncEngine` reads as "nothing to compare against".
    func fetchServerModifiedAt(for item: NoteItem) async throws -> Date? {
        let info = try await fileInfo(for: item.id)
        logger.debug("fetchServerModifiedAt: id=\(item.id, privacy: .public) found=\(info?.isLive == true)")
        // A trashed file still has metadata but is no longer somewhere an edit can land.
        guard let info, info.isLive else { return nil }
        return info.updatedAt
    }

    // MARK: - File Info

    /// Metadata for one file, including the caller's role on it.
    ///
    /// This is the only Drive endpoint that answers for a file the caller can *access* rather than
    /// one they own, so it is what makes shared notes work: the folder listing this used to rely on
    /// belongs to the note's owner and 404s for a recipient. Returns nil when the file is gone
    /// (404) or no longer shared with this account (403) — both mean "not mine to read" rather than
    /// an error worth surfacing.
    func fileInfo(for fileID: String) async throws -> NoteFileInfo? {
        let token = try await authorizedToken()
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)/info") else {
            throw NoteContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteContentError.networkError(underlying: error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 403 {
            logger.debug("fileInfo: id=\(fileID, privacy: .public) unavailable (\(http.statusCode))")
            return nil
        }
        try Self.checkStatus(response)
        do {
            return try NoteFileInfo.decoder.decode(NoteFileInfo.self, from: data)
        } catch {
            logger.error("fileInfo decode failed: id=\(fileID, privacy: .public) \(error, privacy: .public)")
            throw NoteContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Crypto Helpers (internal for unit testing)

    /// Encrypts `text` as [24-byte header][ciphertext] using XChaCha20-Poly1305 secretstream.
    func encrypt(text: String, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> Data {
        guard let stream = xcss.initPush(secretKey: dek) else { throw NoteContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(text.utf8), tag: .FINAL) else {
            throw NoteContentError.encryptionFailed
        }
        return Data(header + cipher)
    }

    /// Reverses `encrypt(text:dek:xcss:)`.
    func decrypt(data: Data, dek: Bytes) throws -> String {
        let headerSize = 24
        guard data.count > headerSize else {
            logger.error("decrypt: data too short (\(data.count) bytes, need >\(headerSize))")
            throw NoteContentError.decryptionFailed
        }
        let header = Array(data.prefix(headerSize))
        let ciphertext = Array(data.dropFirst(headerSize))
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        guard let pull = xcss.initPull(secretKey: dek, header: header) else {
            logger.error("decrypt: initPull failed (dek=\(dek.count) bytes, header=\(header.count) bytes)")
            throw NoteContentError.decryptionFailed
        }
        guard let (plaintext, _) = pull.pull(cipherText: ciphertext) else {
            logger.error("decrypt: pull failed (ciphertext=\(ciphertext.count) bytes) — wrong DEK or corrupted content")
            throw NoteContentError.decryptionFailed
        }
        guard let text = String(bytes: plaintext, encoding: .utf8) else {
            logger.error("decrypt: decrypted \(plaintext.count) bytes are not valid UTF-8")
            throw NoteContentError.decryptionFailed
        }
        return text
    }

    /// Encrypts `{ name, mimeType }` with the DEK, matching the web's encryptMetadata().
    func encryptMetadata(name: String, mimeType: String, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> String {
        let dict: [String: String] = ["name": name, "mimeType": mimeType]
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            throw NoteContentError.encryptionFailed
        }
        guard let stream = xcss.initPush(secretKey: dek) else { throw NoteContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(json), tag: .FINAL) else {
            throw NoteContentError.encryptionFailed
        }
        guard let b64 = Self.sodium.utils.bin2base64(header + cipher, variant: .URLSAFE_NO_PADDING) else {
            throw NoteContentError.encryptionFailed
        }
        return b64
    }

    /// Seals `dek` to *another user's* Curve25519 public key, so it can be handed to Drive's
    /// `POST /files/{id}/key/share` endpoint.
    ///
    /// This is the whole of what makes sharing an encrypted note work: the recipient's copy of the
    /// key is sealed on this device, to their public key, and the server only ever sees the sealed
    /// result. `recipientPublicKey` is the Base64URL string `GET /auth/users/{id}/public-key`
    /// returns.
    func seal(_ dek: Bytes, toRecipientPublicKey recipientPublicKey: String) throws -> String {
        guard let keyData = Data(base64URLEncoded: recipientPublicKey) else {
            logger.error("seal(to:): recipient public key is not valid Base64URL")
            throw NoteContentError.encryptionFailed
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: Array(keyData)) else {
            throw NoteContentError.encryptionFailed
        }
        guard let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw NoteContentError.encryptionFailed
        }
        return b64
    }

    /// The caller's sealed DEK for a file, or nil when the file has no key ref at all — a plaintext
    /// file uploaded outside this app. Distinguishing the two matters when sharing: "no key to
    /// re-wrap" is a fact about the file, not a failure.
    func sealedFileKey(for fileID: String) async throws -> (sealed: String, keyVersion: Int)? {
        let token = try await authorizedToken()
        do {
            return try await fetchSealedDEK(fileID: fileID, token: token)
        } catch NoteContentError.serverError(statusCode: 404) {
            logger.debug("sealedFileKey: id=\(fileID, privacy: .public) has no key ref")
            return nil
        }
    }

    /// Seals `dek` to the caller's *active* Curve25519 public key, and reports
    /// which key version that was — the server records it on the key ref so this
    /// or another device can resolve the right secret key later.
    @MainActor
    func sealDEK(_ dek: Bytes) throws -> (sealed: String, keyVersion: Int) {
        guard let active = KeyringStore.shared.activeKeyPair() else {
            throw NoteContentError.noEncryptionKey
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: active.publicKey) else {
            throw NoteContentError.encryptionFailed
        }
        guard let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw NoteContentError.encryptionFailed
        }
        return (b64, active.version)
    }

    /// Reverses `sealDEK(_:)`, resolving `keyVersion` against this device's keyring.
    ///
    /// `keyVersion` defaults to 1 because key refs written before rotation
    /// existed carry no version, and those are version 1 by definition. A
    /// version this device does not hold throws `KeyringError.missingVersion`,
    /// which names the missing key rather than reporting a bare decrypt failure.
    @MainActor
    func unsealDEK(_ sealedBase64: String, keyVersion: Int = 1) throws -> Bytes {
        let keyPair: (publicKey: [UInt8], secretKey: [UInt8])
        do {
            keyPair = try KeyringStore.shared.keyPair(forVersion: keyVersion)
        } catch KeyringError.noKeyring {
            // No key at all is the same condition the seal path reports, and
            // callers already branch on it. A *missing version* is different and
            // propagates as itself, naming the key that is needed.
            throw NoteContentError.noEncryptionKey
        }
        guard let sealedBytes = Self.sodium.utils.base642bin(sealedBase64, variant: .URLSAFE_NO_PADDING) else {
            logger.error("unsealDEK: sealed DEK is not valid Base64URL")
            throw NoteContentError.decryptionFailed
        }
        guard let dek: Bytes = Self.sodium.box.open(
            anonymousCipherText: sealedBytes,
            recipientPublicKey: keyPair.publicKey,
            recipientSecretKey: keyPair.secretKey
        ) else {
            logger.error("unsealDEK: crypto_box_seal_open returned nil for key version \(keyVersion, privacy: .public)")
            throw NoteContentError.decryptionFailed
        }
        return dek
    }

    // MARK: - Temporary Diagnostics (fingerprints)

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func b64(_ bytes: Bytes) -> String {
        Data(bytes).base64EncodedString()
    }

    // MARK: - Temporary Diagnostics

    /// TEMPORARY debugging aid: logs whether the locally-imported public key matches the
    /// key registered server-side for this account, to distinguish "wrong/stale imported
    /// key" from an actual bug in the seal/unseal or content-encryption code.
    private func debugCompareRegisteredPublicKey(token: String) async {
        guard let active = await KeyringStore.shared.activeKeyPair() else {
            logger.error("debugCompareRegisteredPublicKey: this device holds no keyring")
            return
        }
        let localPubKeyString = Data(active.publicKey).base64URLEncodedString
        do {
            guard let meURL = URL(string: baseURL + "/api/v1/auth/me") else { return }
            var meRequest = URLRequest(url: meURL)
            meRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (meData, _) = try await URLSession.shared.data(for: meRequest)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let me = try decoder.decode(APIUserProfile.self, from: meData)

            guard let keyURL = URL(string: baseURL + "/api/v1/auth/users/\(me.id)/public-key") else { return }
            var keyRequest = URLRequest(url: keyURL)
            keyRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (keyData, keyResponse) = try await URLSession.shared.data(for: keyRequest)
            guard let http = keyResponse as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                logger.error("debugCompareRegisteredPublicKey: server has NO public key registered for user \(me.id, privacy: .public) — imported key (local only) is \(localPubKeyString, privacy: .public)")
                return
            }
            let registered = try decoder.decode(APIPublicKeyResponse.self, from: keyData)
            let matches = registered.publicKey == localPubKeyString
                || Data(base64URLEncoded: registered.publicKey) == Data(base64URLEncoded: localPubKeyString)
            logger.error("debugCompareRegisteredPublicKey: userId=\(me.id, privacy: .public) registered=\(registered.publicKey, privacy: .public) local=\(localPubKeyString, privacy: .public) matches=\(matches)")
        } catch {
            logger.error("debugCompareRegisteredPublicKey: lookup failed (non-fatal): \(error, privacy: .public)")
        }
    }

    // MARK: - HTTP Helpers

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw NoteContentError.notAuthenticated
        }
        return token
    }

    private func upload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw NoteContentError.networkError(underlying: error)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NoteContentError.serverError(statusCode: 0) }
        guard (200...299).contains(http.statusCode) else {
            throw NoteContentError.serverError(statusCode: http.statusCode)
        }
    }

    private func fetchSealedDEK(fileID: String, token: String) async throws -> (sealed: String, keyVersion: Int) {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)/key") else {
            throw NoteContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteContentError.networkError(underlying: error)
        }
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let parsed = try decoder.decode(APIKeyResponse.self, from: data)
            return (parsed.encryptedFileKey, parsed.keyVersion ?? 1)
        } catch {
            throw NoteContentError.decodingError(underlying: error)
        }
    }

    private func fetchEncryptedContent(fileID: String, token: String) async throws -> Data {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)") else {
            throw NoteContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteContentError.networkError(underlying: error)
        }
        try Self.checkStatus(response)
        return data
    }

    private func storeFileKey(fileID: String, encryptedFileKey: String, keyVersion: Int, token: String) async throws {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)/key") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            SetFileKeyBody(encryptedFileKey: encryptedFileKey, keyVersion: keyVersion)
        )

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteContentError.networkError(underlying: error)
        }
        try Self.checkStatus(response)
    }

    private func buildUploadBody(
        encryptedData: Data,
        fileName: String,
        mimeType: String,
        parentFolderID: String?,
        encryptedMetadata: String?
    ) -> MultipartFormBody {
        var form = MultipartFormBody()
        form.appendField(name: "encrypted_metadata", value: encryptedMetadata)
        form.appendField(name: "folder_id", value: parentFolderID)
        form.appendFile(name: "file", fileName: fileName, mimeType: mimeType, data: encryptedData)
        return form
    }
}

// MARK: - API Request Models

/// `PUT /drive/files/{id}/key`. `keyVersion` says which entry of the caller's
/// keyring sealed the DEK; the server stores it opaquely and hands it back.
private struct SetFileKeyBody: Encodable {
    let encryptedFileKey: String
    let keyVersion: Int
}

// MARK: - API Response Models

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
    /// Absent on refs written before rotation existed; those are version 1.
    let keyVersion: Int?
}

private struct APIUserProfile: Decodable {
    let id: String
}

private struct APIPublicKeyResponse: Decodable {
    let userId: String
    let publicKey: String
    /// Which entry of the recipient's keyring this is — recorded on the key ref
    /// when sharing, so they can resolve it against their own keyring.
    let keyVersion: Int?
}

// MARK: - Data + Base64URL

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let r = s.count % 4
        if r != 0 { s += String(repeating: "=", count: 4 - r) }
        self.init(base64Encoded: s)
    }
}
