import CryptoKit
import Foundation

/// Builds the self-signed X.509 certificate this device presents to cohesiond.
///
/// cohesiond accepts any certificate during the TLS handshake and identifies
/// clients by the SHA-256 of their key, so the certificate only needs
/// to be well formed and signed by the key it carries.
nonisolated enum SelfSignedCertificate {
    /// DER of a version 3 certificate for `key`, with `name` as its common name.
    static func make(for key: P256.Signing.PrivateKey, name: String) throws -> Data {
        let distinguishedName = DER.sequence(
            DER.set(DER.sequence(DER.commonNameOID, DER.utf8String(name)))
        )
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(Data([2]))),
            DER.integer(serialNumber()),
            DER.sequence(DER.ecdsaWithSHA256OID),
            distinguishedName,
            DER.sequence(
                DER.utcTime(.now.addingTimeInterval(-86_400)),
                // RFC 5280's value for a certificate with no expiry.
                DER.generalizedTime("99991231235959Z")
            ),
            distinguishedName,
            key.publicKey.derRepresentation
        )
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence(tbs, DER.sequence(DER.ecdsaWithSHA256OID), DER.bitString(signature))
    }

    /// 16 random bytes, positive as DER integers must be.
    private static func serialNumber() -> Data {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        bytes[0] &= 0x7F
        bytes[0] |= 0x01
        return Data(bytes)
    }
}

/// The handful of DER encodings a certificate needs.
private nonisolated enum DER {
    static let ecdsaWithSHA256OID = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let commonNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])

    static func sequence(_ contents: Data...) -> Data {
        element(0x30, contents.reduce(Data(), +))
    }

    static func set(_ contents: Data...) -> Data {
        element(0x31, contents.reduce(Data(), +))
    }

    static func explicit(_ tag: UInt8, _ contents: Data) -> Data {
        element(0xA0 | tag, contents)
    }

    static func integer(_ bytes: Data) -> Data {
        element(0x02, bytes)
    }

    static func utf8String(_ string: String) -> Data {
        element(0x0C, Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return element(0x17, Data(formatter.string(from: date).utf8))
    }

    static func generalizedTime(_ text: String) -> Data {
        element(0x18, Data(text.utf8))
    }

    static func bitString(_ bytes: Data) -> Data {
        // No unused bits in the last byte.
        element(0x03, Data([0]) + bytes)
    }

    private static func element(_ tag: UInt8, _ contents: Data) -> Data {
        Data([tag]) + length(contents.count) + contents
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes = withUnsafeBytes(of: count.bigEndian) { Data($0) }
        bytes = bytes.drop(while: { $0 == 0 })
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }
}
