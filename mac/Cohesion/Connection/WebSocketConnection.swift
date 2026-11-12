import Foundation
import Synchronization

/// A WebSocket to `/connect` on the paired server, over mutual TLS: it
/// presents the app's client certificate and trusts only the server whose
/// key matches the pairing's fingerprint. URLSession answers cohesiond's
/// pings itself; the client pings every 15 seconds too, so a connection that
/// died quietly fails here as well.
final class WebSocketConnection: DaemonConnection {
    /// The longest frame cohesiond reads: `FRAME_LIMIT` in
    /// `unix_socket_exchange.rs`, and axum's default on the WebSocket.
    private static let maximumMessageSize = 64 * 1024 * 1024

    let frames: AsyncThrowingStream<String, any Error>
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var reading: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?

    init(pairing: RemotePairing) throws(ConnectionError) {
        // A pairing whose key can't be read is as good as none.
        guard let session = try? pairing.session() else { throw .unpaired }
        var components = URLComponents(url: pairing.baseURL.appending(path: "connect"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        let socket = session.webSocketTask(with: components.url!)
        // URLSession's default of 1 MiB would drop the connection on a
        // completion carrying images, or the web bundle; cohesiond's frames go
        // up to 64 MiB.
        socket.maximumMessageSize = Self.maximumMessageSize
        let (frames, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        self.session = session
        self.socket = socket
        self.frames = frames
        socket.resume()
        reading = Task {
            do {
                while true {
                    if case .string(let text) = try await socket.receive() {
                        continuation.yield(text)
                    }
                }
            } catch {
                // cohesiond refuses `/connect` to a certificate it doesn't
                // trust, as after the client was removed.
                let refused = (socket.response as? HTTPURLResponse)?.statusCode == 403
                continuation.finish(throwing: refused ? ConnectionError.unpaired : ConnectionError.disconnected(error.localizedDescription))
            }
        }
        heartbeat = Task { await Self.keepAlive(socket) }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ frame: String) async throws {
        try await socket.send(.string(frame))
    }

    func close() {
        reading?.cancel()
        heartbeat?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// Cancels `socket` once a ping goes unanswered for 15 seconds, which
    /// fails `receive()` so the session ends.
    private static func keepAlive(_ socket: URLSessionWebSocketTask) async {
        let pong = Pong()
        while true {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            let answered = pong.answered.withLock { answered in
                defer { answered = false }
                return answered
            }
            guard answered else {
                socket.cancel()
                return
            }
            socket.sendPing { error in
                if error == nil { pong.answered.withLock { $0 = true } }
            }
        }
    }
}

/// Whether the last ping was answered; pongs land on URLSession's queue.
private nonisolated final class Pong: Sendable {
    let answered = Mutex(true)
}
