import Foundation
import os.log

// MARK: - FileEventsMessage

/// The wire format of Drive's file-events relay (`src/shared/file_events/`, and
/// `src/shared/collab_protocol.rs` for the framing).
///
/// A frame is a varint message type followed by an opaque payload. Two types exist; this app sends
/// and reads one of them:
///
/// * `1` — awareness (who is looking at the file). Unused here: the app shows no presence UI, and
///   an unread awareness frame costs nothing.
/// * `2` — file-updated. **A doorbell, not a delivery.** The payload carries a sender id and
///   nothing else; the receiver re-reads the file through the normal, key-holding path. That is
///   what lets a relay the server can see carry updates it cannot read.
enum FileEventsMessage {

    static let awareness = 1
    static let fileUpdated = 2

    // MARK: - Varint

    /// LEB128, as `read_varint`/`write_varint` write it server-side.
    static func writeVarint(_ value: Int, into data: inout Data) {
        var remaining = UInt(value)
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    /// Reads a varint at `offset`, returning the value and the offset just past it. Nil for a
    /// truncated or absurdly long varint rather than a trap: this is parsing bytes off a socket.
    static func readVarint(_ data: Data, at offset: Int = 0) -> (value: Int, next: Int)? {
        var value = 0
        var shift = 0
        var index = offset
        while index < data.count {
            let byte = data[data.startIndex + index]
            value |= Int(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift > 35 { return nil }
        }
        return nil
    }

    // MARK: - Encoding

    /// A `file-updated` frame announcing `clientID` as the sender.
    static func encodeFileUpdated(clientID: String) -> Data {
        var frame = Data()
        writeVarint(fileUpdated, into: &frame)
        frame.append(contentsOf: Array(#"{"clientId":"#.utf8))
        frame.append(contentsOf: Array(#"""#.utf8))
        frame.append(contentsOf: Array(clientID.utf8))
        frame.append(contentsOf: Array(#""}"#.utf8))
        return frame
    }

    /// The sender's client id if `data` is a `file-updated` frame, else nil.
    ///
    /// Every other message type — awareness, or something a future client sends — reads as nil and
    /// is ignored, which is how a signal-only client stays compatible with a chattier one.
    static func decodeFileUpdatedSender(_ data: Data) -> String? {
        guard let (type, offset) = readVarint(data), type == fileUpdated else { return nil }
        let payload = data.dropFirst(offset)
        guard !payload.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        else { return nil }
        return json["clientId"] as? String
    }
}

// MARK: - FileEventsClient

/// Keeps one open note in step with edits made somewhere else — the web app, another device, or
/// another person with edit access — by holding a socket to `GET /api/v1/files/{id}/ws`.
///
/// What travels is a signal, never content: on a peer's update the editor re-reads and decrypts the
/// note itself. Nothing here would work otherwise, since the server has no key for it.
///
/// This is not real-time collaboration. There is no merge, no cursor, and no CRDT — Docs has one
/// (`src/docs/collab/`) and it is a different mechanism deliberately left alone. What this closes
/// is "a change made elsewhere shows up without a manual refresh".
@MainActor
final class FileEventsClient: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var isConnected = false

    // MARK: - Callbacks

    /// Called when a *peer* reports the file changed. Never called for this client's own broadcast.
    var onRemoteUpdate: (() -> Void)?

    // MARK: - Identity

    /// Distinguishes this app's own broadcasts from everyone else's — the relay echoes a frame back
    /// to every session in the room, including the one that sent it.
    let clientID: String

    // MARK: - Dependencies

    weak var authService: AuthService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "FileEventsClient")

    private var task: URLSessionWebSocketTask?
    private var fileID: String?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    /// Set while `disconnect()` is the reason the socket closed, so the receive loop doesn't treat
    /// its own teardown as a connection drop worth retrying.
    private var isStopping = false

    private static let baseBackoff: UInt64 = 2_000_000_000   // 2s
    private static let maximumBackoff: UInt64 = 30_000_000_000 // 30s

    // MARK: - Init

    init(clientID: String = UUID().uuidString) {
        self.clientID = clientID
        super.init()
    }

    // MARK: - Lifecycle

    /// Opens (or re-opens) the relay for `fileID`. Safe to call repeatedly with the same id.
    func connect(to fileID: String) {
        guard FeatureFlags.liveFileEvents else { return }
        if self.fileID == fileID, task != nil { return }
        disconnect()
        self.fileID = fileID
        isStopping = false
        attempt = 0
        openSocket()
    }

    /// Closes the socket and forgets the note. Called when the editor goes away.
    func disconnect() {
        closeSocket()
        fileID = nil
    }

    /// Closes the socket but remembers which note it was for, so [resume] can pick it back up.
    /// For leaving the foreground: iOS tears these down anyway, and doing it deliberately is the
    /// difference between "no news" and "no connection".
    func suspend() {
        closeSocket()
    }

    /// Re-opens the relay for the note this client is still for. No-op if it never had one, or if
    /// the socket survived.
    func resume() {
        guard FeatureFlags.liveFileEvents, fileID != nil, task == nil else { return }
        isStopping = false
        attempt = 0
        openSocket()
    }

    private func closeSocket() {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    // MARK: - Sending

    /// Tells every other session on this file that it just changed. A no-op while disconnected —
    /// a peer that missed the signal picks the change up the next time it loads the note.
    func broadcastFileUpdate() {
        guard let task, isConnected else { return }
        task.send(.data(FileEventsMessage.encodeFileUpdated(clientID: clientID))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.logger.error("broadcast failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Socket

    private func openSocket() {
        guard let fileID else { return }
        Task { [weak self] in
            guard let self else { return }
            // A socket cannot carry an Authorization header, so the token goes in the query string
            // — the same convention every other collab socket in this stack uses. Refresh first:
            // the server closes the handshake on an expired one, and the retry would be identical.
            await self.authService?.refreshTokenIfNeeded()
            guard !self.isStopping, self.fileID == fileID else { return }
            guard let token = KeychainService.load(forKey: AuthService.accessTokenKey),
                  let url = Self.socketURL(fileID: fileID, token: token) else {
                self.logger.error("no token or bad URL — not connecting")
                return
            }

            let task = URLSession.shared.webSocketTask(with: url)
            self.task = task
            task.resume()
            // `URLSessionWebSocketTask` reports the handshake only through its delegate or the
            // first receive; treating the resume as connected keeps this simple, and a socket that
            // never actually opened surfaces as a receive error a moment later.
            self.isConnected = true
            self.receive(on: task)
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.attempt = 0
                    self.receive(on: task)
                case .failure(let error):
                    guard !self.isStopping else { return }
                    self.logger.debug("socket closed: \(error, privacy: .public)")
                    self.isConnected = false
                    self.task = nil
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .data(let data) = message else { return }
        guard let sender = FileEventsMessage.decodeFileUpdatedSender(data) else { return }
        // Our own frame, relayed back to us.
        guard sender != clientID else { return }
        onRemoteUpdate?()
    }

    private func scheduleReconnect() {
        guard fileID != nil, reconnectTask == nil else { return }
        let delay = min(Self.baseBackoff << UInt64(min(attempt, 4)), Self.maximumBackoff)
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isStopping else { return }
                self.reconnectTask = nil
                self.openSocket()
            }
        }
    }

    // MARK: - URL

    /// `https://host` -> `wss://host/api/v1/files/{id}/ws?token=…`, and `http` -> `ws` for a
    /// development server.
    nonisolated static func socketURL(fileID: String, token: String, baseURL: String? = nil) -> URL? {
        let base = baseURL
            ?? UserDefaults.standard.string(forKey: AuthService.serverHostKey)
            ?? AuthService.defaultHost
        guard var components = URLComponents(string: base) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http":  components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        components.path = "/api/v1/files/\(fileID)/ws"
        // Set as an already-encoded query on purpose. The server pulls the token out by slicing the
        // raw query string (`src/shared/file_events/api.rs`) and never percent-decodes it, so a
        // token this end helpfully escaped would arrive as gibberish and fail validation. A JWT is
        // base64url — `A-Z a-z 0-9 - _ .` — so there is nothing in it that needs escaping.
        components.percentEncodedQuery = "token=\(token)"
        return components.url
    }
}
