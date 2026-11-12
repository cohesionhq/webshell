import Foundation

/// A session with cohesiond: the frames it reads, in order, and the frames
/// it writes, JSON text either way.
protocol DaemonConnection: AnyObject {
    /// Each frame as it arrives. Ends when the session closes, or fails
    /// with why the connection broke.
    var frames: AsyncThrowingStream<String, any Error> { get }
    func send(_ frame: String) async throws
    /// Ends the session; safe to call more than once.
    func close()
}

/// Why a session with cohesiond couldn't open or broke.
nonisolated enum ConnectionError: LocalizedError {
    /// The server doesn't trust this app's pairing, or it can't be read.
    case unpaired
    case unreachable(String)
    case disconnected(String)
    /// cohesiond refused the session, saying why.
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unpaired: "The server doesn’t trust this device any more."
        case .unreachable(let reason): "Couldn’t reach Cohesion: \(reason)"
        case .disconnected(let reason): "Lost the connection to Cohesion: \(reason)"
        case .refused(let reason): reason
        }
    }
}

/// Where cohesiond is, and who this app is to it.
nonisolated enum DaemonRoute: Equatable, Sendable {
    /// A server elsewhere, over mutual TLS.
    case remote(RemotePairing)
    #if os(macOS)
    /// This Mac's cohesiond, through its Unix socket.
    case local(socket: String, identity: LocalIdentity)

    /// The socket cohesiond listens on with its default directory, as
    /// `paths::default_socket_path` puts it on macOS.
    static var defaultSocket: String {
        URL.applicationSupportDirectory
            .appending(path: "cohesiond/cohesiond.sock")
            .path(percentEncoded: false)
    }
    #endif

    /// Where the daemon is, as `/client` tells the web UI.
    var target: String {
        switch self {
        case .remote(let pairing): pairing.baseURL.absoluteString
        #if os(macOS)
        case .local(let socket, _): socket
        #endif
        }
    }

    /// Opens a new session.
    @MainActor
    func connect() throws(ConnectionError) -> any DaemonConnection {
        switch self {
        case .remote(let pairing):
            return try WebSocketConnection(pairing: pairing)
        #if os(macOS)
        case .local(let socket, let identity):
            return try SocketConnection(path: socket, identity: identity)
        #endif
        }
    }
}
