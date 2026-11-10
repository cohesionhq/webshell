#if os(macOS)
import Foundation

/// Who this client is on cohesiond's Unix socket (`LocalIdentity` in
/// `cohesion-core/src/auth/local_handshake.rs`): a random key the daemon
/// knows the client by, and the name a client new to it is listed under.
/// The socket's file permissions stand in for pairing.
nonisolated struct LocalIdentity: Codable, Equatable, Sendable {
    let key: String
    let name: String

    /// A new identity named `name`, with 32 random bytes as its key in hex.
    init(name: String) {
        var generator = SystemRandomNumberGenerator()
        key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        self.name = name
    }
}
#endif
