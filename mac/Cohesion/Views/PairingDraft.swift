import Foundation
import Observation

/// What a pairing form holds while someone fills it in, and the pairing it
/// starts, shared by the Mac's form and the iPad's sheet.
@Observable
final class PairingDraft {
    var name = PairingStore.generatedName
    var setupCode = ""
    /// What to call the account; blank leaves it named for its server.
    var accountName = ""
    private(set) var isPairing = false
    private(set) var error: String?

    var canPair: Bool {
        !setupCode.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && !isPairing
    }

    /// Registers with `store`, then runs `onPair` with the pairing once the
    /// store holds it.
    func pair(with store: PairingStore, onPair: @escaping (RemotePairing) -> Void) {
        guard canPair else { return }
        isPairing = true
        error = nil
        Task {
            do throws(PairingError) {
                let pairing = try await store.pair(setupCode: setupCode, name: name, accountName: accountName)
                setupCode = ""
                accountName = ""
                onPair(pairing)
            } catch {
                self.error = error.localizedDescription
            }
            isPairing = false
        }
    }
}
