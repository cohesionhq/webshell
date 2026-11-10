import CryptoKit
import Foundation
import Security

/// Presents this app's client certificate, and trusts only the server whose
/// key matches the fingerprint from its setup code. cohesiond signs a fresh
/// self-signed certificate on every start, so its key is what stays the same.
nonisolated final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let serverFingerprint: String

    init(identity: SecIdentity, serverFingerprint: String) {
        self.identity = identity
        self.serverFingerprint = serverFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  fingerprint(of: trust) == serverFingerprint
            else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    /// Lowercase hex SHA-256 of the server certificate's SubjectPublicKeyInfo.
    private func fingerprint(of trust: SecTrust) -> String? {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point)
        else { return nil }
        return SHA256.hash(data: publicKey.derRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
