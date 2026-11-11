import Foundation
import Observation
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// This app's identities with cohesiond, kept in the keychain: its pairings
/// with servers elsewhere, each an account, and, on a Mac, its key on the
/// Mac's own server.
@Observable
final class PairingStore {
    private static let remotesItem = KeychainItem<[RemotePairing]>(account: "pairings")
    /// Where a single pairing was kept before the app took several.
    private static let legacyItem = KeychainItem<RemotePairing>(account: "pairing")
    #if os(macOS)
    private static let localItem = KeychainItem<LocalIdentity>(account: "localIdentity")
    #endif

    /// The servers this app paired with, in the order they were made.
    private(set) var remotes: [RemotePairing]

    /// Loads the pairings. A single pairing kept by an earlier version
    /// becomes the first, and is removed once the list is saved.
    init() {
        if let remotes = Self.remotesItem.load() {
            self.remotes = remotes
        } else if let legacy = Self.legacyItem.load() {
            Self.remotesItem.save([legacy])
            if Self.remotesItem.load() != nil { Self.legacyItem.remove() }
            remotes = [legacy]
        } else {
            remotes = []
        }
    }

    /// The account with this id, while the app is still paired with it.
    func remote(id: String) -> RemotePairing? {
        remotes.first { $0.id == id }
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

    /// Registers as `name` with the server that printed `setupCode`, as the
    /// account `accountName` (blank for none), replacing an earlier pairing
    /// with the same server once it has.
    func pair(setupCode: String, name: String, accountName: String) async throws(PairingError) -> RemotePairing {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = try await RemotePairing.register(setupCode: setupCode, name: name, accountName: accountName)
        if let index = remotes.firstIndex(where: { $0.id == pairing.id }) {
            remotes[index] = pairing
        } else {
            remotes.append(pairing)
        }
        Self.remotesItem.save(remotes)
        return pairing
    }

    /// Forgets the account with this id, and the key its server trusts, so
    /// windows on it have to pair again.
    func unpair(id: String) {
        remotes.removeAll { $0.id == id }
        Self.remotesItem.save(remotes)
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
