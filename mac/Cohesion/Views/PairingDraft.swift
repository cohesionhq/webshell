import Foundation
import Observation

/// What a pairing form holds while someone fills it in, and the pairing it
/// starts, shared by the Mac's form and the iPad's sheet.
@Observable
final class PairingDraft {
    var name = PairingStore.generatedName
    var setupCode = ""
    private(set) var isPairing = false
    private(set) var error: String?

    var canPair: Bool {
        !setupCode.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && !isPairing
    }

    /// Registers with `store`, then runs `onPair` once it holds the pairing.
    func pair(with store: PairingStore, onPair: @escaping () -> Void) {
        guard canPair else { return }
        isPairing = true
        error = nil
        Task {
            do throws(PairingError) {
                try await store.pair(setupCode: setupCode, name: name)
                setupCode = ""
                onPair()
            } catch {
                self.error = error.localizedDescription
            }
            isPairing = false
        }
    }
}
