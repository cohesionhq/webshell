import Foundation

/// What a setup code tells a new client: `base64("<key>|<address>|<fingerprint>")`.
/// The address is an ip or a DNS name, which means cohesiond's default port,
/// or `host:port` (`[v6]:port` for IPv6).
nonisolated struct SetupCode: Sendable {
    /// The port cohesiond listens on unless the setup code's address names another.
    static let defaultPort = 3000

    /// The secret cohesiond expects on `/register`.
    let key: String
    /// The ip or DNS name cohesiond can be reached at.
    let host: String
    /// The HTTPS port clients connect to.
    let port: Int
    /// SHA-256 of cohesiond's key, which its certificate must match.
    let fingerprint: String

    init(_ code: String) throws(PairingError) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let text = String(data: data, encoding: .utf8)
        else { throw .invalidSetupCode }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw .invalidSetupCode }
        let address = try Self.address(String(parts[1]))
        key = String(parts[0])
        host = address.host
        port = address.port
        fingerprint = String(parts[2])
    }

    /// Splits `host`, `host:port` or `[v6]:port`; a bare IPv6 address has several colons and no port.
    private static func address(_ text: String) throws(PairingError) -> (host: String, port: Int) {
        let host: Substring
        let portText: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]"),
                  text[text.index(after: close)...].hasPrefix(":")
            else { throw .invalidSetupCode }
            host = text[text.index(after: text.startIndex)..<close]
            portText = text[text.index(close, offsetBy: 2)...]
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = text[..<colon]
            portText = text[text.index(after: colon)...]
        } else {
            return (text, defaultPort)
        }
        guard let port = UInt16(portText), port > 0 else { throw .invalidSetupCode }
        return (String(host), Int(port))
    }
}

/// Why pairing didn't happen.
enum PairingError: LocalizedError {
    case invalidSetupCode
    case cannotCreateIdentity
    /// cohesiond refused the registration, saying why.
    case refused(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidSetupCode: "That isn't a valid setup code."
        case .cannotCreateIdentity: "Couldn't create a certificate."
        case .refused(let reason): reason
        case .unreachable(let reason): "Couldn’t reach Cohesion: \(reason)"
        }
    }
}
