import CryptoKit
import Foundation
import Security

/// This device's registration with a cohesiond elsewhere, made from a setup
/// code: where the server is, the key its certificate must carry, and the
/// certificate and key this device presents to it.
nonisolated struct RemotePairing: Codable, Equatable, Sendable {
    /// The server's address, as the setup code gave it.
    let host: String
    /// The server's HTTPS port, as the setup code gave it.
    let port: Int
    /// SHA-256 of the server's key, which its certificate must match.
    let serverFingerprint: String
    /// The raw P-256 private key whose certificate cohesiond trusts.
    let privateKey: Data
    /// DER of this device's self-signed certificate.
    let certificate: Data

    /// Registers a new key and certificate, named `name`, with the server
    /// that printed `setupCode`.
    static func register(setupCode: String, name: String) async throws(PairingError) -> RemotePairing {
        let code = try SetupCode(setupCode)
        let key = P256.Signing.PrivateKey()
        let certificate: Data
        do {
            certificate = try SelfSignedCertificate.make(for: key, name: name)
        } catch {
            throw .cannotCreateIdentity
        }
        let pairing = RemotePairing(
            host: code.host,
            port: code.port,
            serverFingerprint: code.fingerprint,
            privateKey: key.rawRepresentation,
            certificate: certificate
        )
        try await pairing.post(register: ["setup_key": code.key, "client_name": name])
        return pairing
    }

    /// `https://host:port`, with an IPv6 address in brackets.
    var baseURL: URL {
        let host = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(host):\(port)")!
    }

    /// The certificate and key, as URLSession presents them for client authentication.
    func identity() throws(PairingError) -> SecIdentity {
        let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        guard let key,
              let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
              let secCertificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let identity = SecIdentityCreate(nil, secCertificate, secKey)
        else { throw .cannotCreateIdentity }
        return identity
    }

    /// A session presenting this pairing's certificate and trusting only its server.
    func session() throws(PairingError) -> URLSession {
        let delegate = TrustDelegate(identity: try identity(), serverFingerprint: serverFingerprint)
        return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    /// Asks cohesiond to trust this pairing's certificate.
    ///
    /// cohesiond judges a connection by its certificate when it opens, so the
    /// session that registered stays unregistered and is thrown away.
    private func post(register body: [String: String]) async throws(PairingError) {
        let session = try session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appending(path: "register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if let reply = try? JSONDecoder().decode(RegisterReply.self, from: data) {
            if let error = reply.error { throw .refused(error.message) }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw .refused(text.isEmpty ? "HTTP \(status)" : text)
    }
}

/// The reply frame around `/register`'s outcome; only a refusal is read.
private nonisolated struct RegisterReply: Decodable {
    struct Refusal: Decodable {
        let message: String
    }

    let error: Refusal?
}
