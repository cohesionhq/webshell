#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// cohesiond's Unix socket on this Mac, whose file permissions stand in for
/// pairing. Before the session it identifies this client with the socket's
/// own handshake, as `local_acceptor.rs` reads it: an `identity` line out,
/// one reply line back, which `frames` never yields. Frames are then
/// newline-delimited JSON, as `unix_socket_exchange.rs` reads and writes
/// them. A thread of its own reads the socket.
final class SocketConnection: DaemonConnection {
    let frames: AsyncThrowingStream<String, any Error>
    private let socket: SharedSocket

    init(path: String, identity: LocalIdentity) throws(ConnectionError) {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .unreachable(SocketConnection.lastError) }
        // A write after cohesiond goes away fails with EPIPE rather than
        // raising SIGPIPE, which would end the app.
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        // Leaves room for the terminating zero `sockaddr_un()` starts with.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw .unreachable("The socket path \(path) is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = SocketConnection.lastError
            Darwin.close(descriptor)
            throw .unreachable(reason)
        }

        let socket = SharedSocket(descriptor)
        // Frames written after it wait in the socket until cohesiond accepts it.
        let line = String(decoding: try! JSONEncoder().encode(identity), as: UTF8.self) + "\n"
        if let code = socket.write(Array(line.utf8)) {
            Darwin.close(descriptor)
            throw .unreachable(String(cString: strerror(code)))
        }
        let (frames, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        self.socket = socket
        self.frames = frames
        Thread { socket.readLines(into: continuation) }.start()
    }

    deinit {
        socket.shutDown()
    }

    func send(_ frame: String) async throws {
        if let code = socket.write(Array((frame + "\n").utf8)) {
            throw ConnectionError.disconnected(String(cString: strerror(code)))
        }
    }

    func close() {
        socket.shutDown()
    }

    private static var lastError: String {
        String(cString: strerror(errno))
    }
}

/// cohesiond's answer to a `LocalIdentity` (`LocalHandshakeReply`).
private nonisolated enum LocalHandshakeReply: Decodable {
    case accepted
    case refused(String)

    private enum CodingKeys: String, CodingKey {
        case outcome, reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "accepted": self = .accepted
        default: self = .refused(try container.decode(String.self, forKey: .reason))
        }
    }
}

/// A connected socket shared by the thread reading it and the main actor
/// writing it. Only the reading thread closes it, under the lock, so a write
/// never lands on a descriptor that was closed and reused.
private nonisolated final class SharedSocket: Sendable {
    private let descriptor: Int32
    /// The descriptor until the reading thread closes it.
    private let open: Mutex<Int32?>

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        open = Mutex(descriptor)
    }

    /// Reads the handshake's reply, then each line after it until cohesiond
    /// closes the socket or `shutDown` is called, yielding those, then closes
    /// the socket and ends the stream. A refused handshake ends it with why.
    func readLines(into continuation: AsyncThrowingStream<String, any Error>.Continuation) {
        let capacity = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        var pending: [UInt8] = []
        var failure: (any Error)?
        var accepted = false
        reading: while true {
            let count = Darwin.read(descriptor, &buffer, capacity)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                failure = ConnectionError.disconnected(String(cString: strerror(errno)))
                break
            }
            pending.append(contentsOf: buffer[0..<count])
            while let end = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[0..<end])
                pending.removeSubrange(0...end)
                if line.isEmpty { continue }
                guard accepted else {
                    switch try? JSONDecoder().decode(LocalHandshakeReply.self, from: line) {
                    case .accepted: accepted = true
                    case .refused(let reason): failure = ConnectionError.refused(reason)
                    case nil: failure = ConnectionError.disconnected("Cohesion answered the handshake with something else.")
                    }
                    if accepted { continue } else { break reading }
                }
                continuation.yield(String(decoding: line, as: UTF8.self))
            }
        }
        open.withLock { descriptor in
            if let fd = descriptor { Darwin.close(fd) }
            descriptor = nil
        }
        continuation.finish(throwing: failure)
    }

    /// Writes all of `bytes`, returning the error number when it can't.
    func write(_ bytes: [UInt8]) -> Int32? {
        open.withLock { (descriptor: inout Int32?) -> Int32? in
            guard let fd = descriptor else { return EPIPE }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress, $0.count)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
    }

    /// Wakes the reading thread, which then closes the socket.
    func shutDown() {
        open.withLock { descriptor in
            if let fd = descriptor { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }
}

#endif
