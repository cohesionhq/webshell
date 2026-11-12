import CryptoKit
import Foundation
import Security

/// This device's registration with a cohesiond elsewhere, made from a setup
/// code: where the server is, the key its certificate must carry, the
/// certificate and key this device presents to it, and what the account is
/// called. Each is an account the app can open a window on.
nonisolated struct RemotePairing: Codable, Equatable, Identifiable, Sendable {
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
    /// What the person called the account when they paired, if anything.
    var accountName: String? = nil

    /// Registers a new key and certificate, named `name`, with the server
    /// that printed `setupCode`, as the account `accountName` (blank for none).
    static func register(setupCode: String, name: String, accountName: String) async throws(PairingError) -> RemotePairing {
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
            certificate: certificate,
            accountName: accountName.isEmpty ? nil : accountName
        )
        try await pairing.post(register: ["setup_key": code.key, "client_name": name])
        return pairing
    }

    /// Which server this is: pairing with the same server again replaces it.
    var id: String { serverFingerprint }

    /// What the account is called: the name given when pairing, or the
    /// server's name or address, without the port.
    var label: String { accountName ?? host }

    /// Names the website data store this account's pages keep their storage
    /// in, so no account's pages see another's: the first half of the
    /// SHA-256 of the server's fingerprint.
    var dataStoreID: UUID {
        let digest = Array(SHA256.hash(data: Data(serverFingerprint.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
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
