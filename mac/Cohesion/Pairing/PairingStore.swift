import Foundation
import Observation
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// This app's identities with cohesiond, kept in the keychain: its pairing
/// with a server elsewhere and, on a Mac, its key on the Mac's own server.
@Observable
final class PairingStore {
    private static let remoteItem = KeychainItem<RemotePairing>(account: "pairing")
    #if os(macOS)
    private static let localItem = KeychainItem<LocalIdentity>(account: "localIdentity")
    #endif

    /// The server this app paired with, if it has.
    private(set) var remote: RemotePairing?

    init() {
        remote = Self.remoteItem.load()
    }

    /// The computer's name, as the Sharing settings show it ("Mac mini"), or
    /// the device's: the first part of the name pairing suggests.
    static var deviceName: String {
        #if os(macOS)
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName
        #else
        UIDevice.current.name
        #endif
    }

    /// The name a new client is offered: the device's name and the app's,
    /// as `generatedClientName(device:client:)` formats them, as
    /// `Mac mini (Cohesion)`.
    static var generatedName: String {
        let info = Bundle.main.infoDictionary
        let app = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
        return generatedClientName(device: deviceName, client: app ?? "Cohesion")
    }

    /// Registers as `name` with the server that printed `setupCode`,
    /// replacing any earlier pairing once it has.
    func pair(setupCode: String, name: String) async throws(PairingError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = try await RemotePairing.register(setupCode: setupCode, name: name)
        Self.remoteItem.save(pairing)
        remote = pairing
    }

    /// Forgets the pairing with the server elsewhere, and the key it trusts,
    /// so the app has to pair again.
    func unpair() {
        Self.remoteItem.remove()
        remote = nil
    }

    #if os(macOS)
    /// This app's key on the Mac's own cohesiond, made the first time it is
    /// asked for and kept, so the app stays one client there.
    var localIdentity: LocalIdentity {
        if let identity = Self.localItem.load() { return identity }
        let identity = LocalIdentity(name: Self.generatedName)
        Self.localItem.save(identity)
        return identity
    }
    #endif
}
